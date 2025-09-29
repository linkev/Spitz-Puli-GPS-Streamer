import asyncio
import logging
import os
from datetime import datetime
from typing import Optional, Dict, List, Tuple, Any
from contextlib import asynccontextmanager

import pynmea2
import uvicorn
from fastapi import FastAPI, Request, HTTPException
from influxdb_client import InfluxDBClient, Point
from influxdb_client.client.write_api import SYNCHRONOUS

# Configuration
INFLUXDB_URL = os.getenv("INFLUXDB_URL", "http://localhost:8086")
INFLUXDB_TOKEN = os.getenv("INFLUXDB_TOKEN", "glinet-gps-token")
INFLUXDB_ORG = os.getenv("INFLUXDB_ORG", "glinet-gps")
INFLUXDB_BUCKET = os.getenv("INFLUXDB_BUCKET", "gps_data")
LOG_LEVEL = os.getenv("LOG_LEVEL", "DEBUG")

# Setup logging
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# Global variables
influx_client = None
write_api = None
stats = {
    "sentences_received": 0,
    "sentences_parsed": 0,
    "points_written": 0,
    "last_position": None,
    "last_update": None
}


def safe_float(value: Any) -> Optional[float]:
    """Safely convert value to float"""
    try:
        return float(value) if value is not None and value != '' else None
    except (ValueError, TypeError):
        return None


def safe_int(value: Any) -> Optional[int]:
    """Safely convert value to int"""
    try:
        return int(value) if value is not None and value != '' else None
    except (ValueError, TypeError):
        return None


def add_field_if_valid(point: Point, field_name: str, value: Any, converter=None) -> bool:
    """Add field to point if value is valid, return True if field was added"""
    if value is not None and value != '':
        converted = converter(value) if converter else value
        if converted is not None:
            point.field(field_name, converted)
            return True
    return False


def create_position_point(msg, timestamp: datetime, sentence_type: str) -> Optional[Point]:
    """Create GPS position point from NMEA message"""
    if not (hasattr(msg, 'latitude') and hasattr(msg, 'longitude') and msg.latitude and msg.longitude):
        return None
    
    lat, lon = safe_float(msg.latitude), safe_float(msg.longitude)
    if lat is None or lon is None:
        return None
    
    point = Point("gps_position").field("latitude", lat).field("longitude", lon).time(timestamp)
    
    # Add common fields
    field_mappings = [
        ("altitude", "altitude", safe_float),
        ("gps_qual", "fix_quality", safe_int),
        ("num_sats", "satellites", safe_int),
        ("horizontal_dil", "hdop", safe_float),
        ("spd_over_grnd", "speed_knots", safe_float),
        ("true_course", "course", safe_float),
        ("timestamp", "gps_time", str)
    ]
    
    for attr, field, converter in field_mappings:
        if hasattr(msg, attr):
            add_field_if_valid(point, field, getattr(msg, attr), converter)
    
    # Add speed conversions if speed exists
    if hasattr(msg, 'spd_over_grnd') and msg.spd_over_grnd:
        speed = safe_float(msg.spd_over_grnd)
        if speed is not None:  # Allow 0.0 speed
            point.field("speed_mph", speed * 1.15078).field("speed_kmh", speed * 1.852)
    
    point.field("source_sentence", sentence_type)
    stats.update({
        "last_position": {"lat": lat, "lon": lon},
        "last_update": timestamp.isoformat()
    })
    
    logger.debug(f"Position point: {sentence_type} lat={lat:.6f}, lon={lon:.6f}")
    return point


def create_satellite_point(msg, timestamp: datetime) -> Optional[Point]:
    """Create satellite data point from GPGSV message"""
    point = Point("satellite_data").time(timestamp)
    fields_added = False
    
    # Basic GSV fields
    basic_fields = [
        ("num_messages", "total_messages", safe_int),
        ("msg_num", "message_number", safe_int),
        ("num_sv_in_view", "satellites_in_view", safe_int)
    ]
    
    for attr, field, converter in basic_fields:
        if hasattr(msg, attr):
            if add_field_if_valid(point, field, getattr(msg, attr), converter):
                fields_added = True
    
    # Process satellite data
    satellites_processed = 0
    for i in range(1, 5):
        sv_prn = getattr(msg, f'sv_prn_{i:02d}', None)
        if sv_prn and sv_prn != '':
            sat_prn = safe_int(sv_prn)
            if sat_prn:
                # Add satellite-specific fields
                sat_fields = [
                    (f'elevation_{i:02d}', f"sat_{sat_prn}_elevation", safe_float),
                    (f'azimuth_{i:02d}', f"sat_{sat_prn}_azimuth", safe_float),
                    (f'snr_{i:02d}', f"sat_{sat_prn}_snr", safe_float)
                ]
                
                point.field(f"sat_{sat_prn}_prn", sat_prn)
                
                for attr, field, converter in sat_fields:
                    if hasattr(msg, attr):
                        add_field_if_valid(point, field, getattr(msg, attr), converter)
                
                satellites_processed += 1
                fields_added = True
    
    if satellites_processed > 0:
        point.field("satellites_processed", satellites_processed)
    
    # Always include basic GSV data even if no individual satellites were processed
    point.field("source_sentence", "$GPGSV")
    
    return point if fields_added else None


def create_dop_point(msg, timestamp: datetime) -> Optional[Point]:
    """Create DOP data point from GPGSA message"""
    point = Point("gps_dop_data").time(timestamp)
    fields_added = False
    
    # Basic GSA fields
    if hasattr(msg, 'mode') and msg.mode:
        point.field("mode", str(msg.mode))
        fields_added = True
    
    if hasattr(msg, 'mode_fix_type') and msg.mode_fix_type:
        fix_type = safe_int(msg.mode_fix_type)
        if fix_type:
            point.field("fix_type", fix_type)
            fields_added = True
    
    # Active satellites
    active_satellites = []
    for i in range(1, 13):
        sv_id = getattr(msg, f'sv_id{i:02d}', None)
        if sv_id and sv_id != '':
            sat_id = safe_int(sv_id)
            if sat_id:
                active_satellites.append(sat_id)
                point.field(f"active_sat_{i}", sat_id)
                fields_added = True
    
    if active_satellites:
        point.field("active_satellites_count", len(active_satellites))
        point.field("active_satellites_list", ','.join(map(str, active_satellites)))
        fields_added = True
    
    # DOP values
    dop_fields = [("pdop", "pdop"), ("hdop", "hdop"), ("vdop", "vdop")]
    for attr, field in dop_fields:
        if hasattr(msg, attr):
            if add_field_if_valid(point, field, getattr(msg, attr), safe_float):
                fields_added = True
    
    if hasattr(msg, 'system_id') and msg.system_id:
        point.field("system_id", str(msg.system_id))
        fields_added = True
    
    point.field("source_sentence", "$GPGSA")
    
    return point if fields_added else None


def create_navigation_point(msg, timestamp: datetime) -> Optional[Point]:
    """Create navigation data point from GPVTG message"""
    point = Point("gps_navigation_data").time(timestamp)
    fields_added = False
    
    # Track and speed fields
    nav_fields = [
        ("true_track", "true_track_degrees", safe_float),
        ("mag_track", "magnetic_track_degrees", safe_float),
        ("spd_over_grnd_kts", "speed_knots", safe_float),
        ("spd_over_grnd_kmph", "speed_kmh", safe_float)
    ]
    
    for attr, field, converter in nav_fields:
        if hasattr(msg, attr):
            if add_field_if_valid(point, field, getattr(msg, attr), converter):
                fields_added = True
    
    if hasattr(msg, 'faa_mode') and msg.faa_mode:
        point.field("faa_mode", str(msg.faa_mode))
        fields_added = True
    
    point.field("source_sentence", "$GPVTG")
    
    return point if fields_added else None


def parse_nmea_sentence(sentence: str) -> Optional[Point]:
    """Parse NMEA sentence and return InfluxDB point if valid"""
    try:
        msg = pynmea2.parse(sentence)
        timestamp = datetime.utcnow()
        sentence_type = sentence[:6]
        
        # Route to appropriate parser based on sentence type
        parsers = {
            ('$GPGGA', '$GPRMC'): lambda: create_position_point(msg, timestamp, sentence_type),
            '$GPGSV': lambda: create_satellite_point(msg, timestamp),
            '$GPGSA': lambda: create_dop_point(msg, timestamp),
            '$GPVTG': lambda: create_navigation_point(msg, timestamp)
        }
        
        for key, parser in parsers.items():
            if sentence_type in (key if isinstance(key, tuple) else (key,)):
                try:
                    point = parser()
                    if point:
                        stats["sentences_parsed"] += 1
                        logger.debug(f"✅ Parsed {sentence_type} successfully")
                        return point
                    else:
                        logger.debug(f"⚠️ {sentence_type} parser returned no point (empty/invalid data)")
                        return None
                except Exception as parse_error:
                    logger.warning(f"Parse error in {sentence_type} parser: {parse_error}")
                    return None
        
        logger.debug(f"Skipping {sentence_type}: no parser available")
        
    except Exception as e:
        logger.warning(f"NMEA parse error for {sentence[:6]}: {e}")
    
    return None


def parse_nmea_sentences(sentences: List[str]) -> Tuple[List[Point], List[str], List[str], Dict[str, int]]:
    """Parse multiple NMEA sentences and return processing results"""
    points_to_write = []
    parsed_sentences = []
    skipped_sentences = []
    sentence_type_counts = {}
    
    for sentence in sentences:
        sentence = sentence.strip()
        if not sentence or not sentence.startswith('$'):
            skipped_sentences.append("invalid")
            continue
        
        if '\n' in sentence or '\r' in sentence:
            skipped_sentences.append("embedded-newlines")
            continue
        
        sentence_type = sentence[:6]
        sentence_type_counts[sentence_type] = sentence_type_counts.get(sentence_type, 0) + 1
        
        point = parse_nmea_sentence(sentence)
        if point:
            points_to_write.append(point)
            parsed_sentences.append(sentence_type)
        else:
            skipped_sentences.append(sentence_type)
    
    return points_to_write, parsed_sentences, skipped_sentences, sentence_type_counts


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage application lifespan events"""
    logger.info("Starting GL.iNet GPS Streamer Service")
    await asyncio.sleep(2)
    
    success = await init_influxdb()
    if not success:
        logger.error("Failed to initialize InfluxDB connection")
        raise RuntimeError("InfluxDB initialization failed")
    
    logger.info("GL.iNet GPS Streamer Service started successfully")
    yield
    
    logger.info("Shutting down GL.iNet GPS Streamer Service")
    if influx_client:
        influx_client.close()


app = FastAPI(
    title="GL.iNet GPS Streamer Service",
    description="GPS data streaming service from GL.iNet GL-X3000/GL-XE3000 routers to InfluxDB",
    version="1.0.0",
    lifespan=lifespan
)


async def init_influxdb():
    """Initialize InfluxDB connection"""
    global influx_client, write_api
    try:
        influx_client = InfluxDBClient(url=INFLUXDB_URL, token=INFLUXDB_TOKEN, org=INFLUXDB_ORG)
        write_api = influx_client.write_api(write_options=SYNCHRONOUS)
        
        health = influx_client.health()
        logger.info(f"InfluxDB connection established. Status: {health.status}")
        return True
    except Exception as e:
        logger.error(f"Failed to connect to InfluxDB: {e}")
        return False


@app.post("/gps")
async def receive_gps_data(request: Request):
    """Receive raw GPS NMEA data"""
    try:
        raw_data = await request.body()
        nmea_data = raw_data.decode('utf-8').strip()
        
        if not nmea_data:
            raise HTTPException(status_code=400, detail="No GPS data received")
        
        logger.debug(f"Raw data: {len(raw_data)} bytes")
        
        # Process sentences
        normalized_data = nmea_data.replace('\r\n', '\n').replace('\r', '\n')
        sentences = [line.strip() for line in normalized_data.split('\n') if line.strip()]
        stats["sentences_received"] += len(sentences)
        
        logger.info(f"Received {len(sentences)} NMEA sentences")
        
        points_to_write, parsed_sentences, skipped_sentences, sentence_type_counts = parse_nmea_sentences(sentences)
        
        # Create summary
        type_summary = []
        for sentence_type, count in sentence_type_counts.items():
            short_type = sentence_type.replace('$GP', '').replace('$GN', '').replace('$GL', '')
            type_summary.append(f"{short_type}:{count}")
        
        batch_summary = " ".join(type_summary) if type_summary else "EMPTY"
        logger.info(f"📊 Batch: {len(sentences)} total, {len(points_to_write)} parsed, {len(skipped_sentences)} skipped")
        logger.info(f"📈 Types: [{batch_summary}]")
        
        # Detailed breakdown by sentence type
        parsed_counts = {}
        skipped_counts = {}
        
        for sentence_type in parsed_sentences:
            parsed_counts[sentence_type] = parsed_counts.get(sentence_type, 0) + 1
        
        for sentence_type in skipped_sentences:
            if sentence_type not in ["invalid", "embedded-newlines"]:
                skipped_counts[sentence_type] = skipped_counts.get(sentence_type, 0) + 1
        
        # Log parsed sentences
        if parsed_counts:
            parsed_summary = []
            for sentence_type, count in parsed_counts.items():
                short_type = sentence_type.replace('$GP', '')
                parsed_summary.append(f"{short_type}:{count}")
            logger.info(f"✅ Parsed: [{' '.join(parsed_summary)}]")
        
        # Log skipped sentences  
        if skipped_counts:
            skipped_summary = []
            for sentence_type, count in skipped_counts.items():
                short_type = sentence_type.replace('$GP', '')
                skipped_summary.append(f"{short_type}:{count}")
            logger.info(f"⏭️ Skipped: [{' '.join(skipped_summary)}]")
        
        # Group by measurement type for InfluxDB
        measurement_types = {}
        type_mapping = {
            ('$GPGGA', '$GPRMC'): 'Position',
            '$GPGSV': 'Satellites',
            '$GPGSA': 'DOP/Precision',
            '$GPVTG': 'Navigation'
        }
        
        for sentence_type in parsed_sentences:
            for types, category in type_mapping.items():
                if sentence_type in (types if isinstance(types, tuple) else (types,)):
                    measurement_types.setdefault(category, []).append(sentence_type)
        
        # Log measurement types being written to InfluxDB
        for meas_type, sentence_list in measurement_types.items():
            count = len(sentence_list)
            logger.info(f"📍 {meas_type}: {count} points")
        
        # Write to InfluxDB
        if points_to_write and write_api:
            try:
                write_api.write(bucket=INFLUXDB_BUCKET, record=points_to_write)
                stats["points_written"] += len(points_to_write)
                logger.info(f"✅ Wrote {len(points_to_write)} points to InfluxDB")
            except Exception as e:
                logger.error(f"InfluxDB write failed: {e}")
                raise HTTPException(status_code=500, detail="Database write failed")
        elif not points_to_write:
            logger.warning("No valid GPS data points to write")
        
        return {
            "status": "success",
            "sentences_processed": len(sentences),
            "points_written": len(points_to_write),
            "batch_summary": batch_summary,
            "sentence_types": sentence_type_counts,
            "parsed_counts": parsed_counts,
            "skipped_counts": skipped_counts,
            "measurement_types": {k: len(v) for k, v in measurement_types.items()}
        }
        
    except Exception as e:
        logger.error(f"Error processing GPS data: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/health")
async def health_check():
    """Health check endpoint"""
    try:
        influx_status = influx_client and influx_client.health().status == "pass"
        return {
            "status": "healthy" if influx_status else "unhealthy",
            "influxdb": "connected" if influx_status else "disconnected",
            "stats": stats
        }
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return {"status": "unhealthy", "error": str(e)}


@app.get("/stats")
async def get_stats():
    """Get service statistics"""
    return stats


@app.post("/debug")
async def debug_raw_data(request: Request):
    """Debug endpoint to see raw data structure"""
    try:
        raw_data = await request.body()
        nmea_data = raw_data.decode('utf-8')
        
        return {
            "raw_length": len(raw_data),
            "decoded_length": len(nmea_data),
            "raw_preview": repr(nmea_data[:300]),
            "contains_cr": '\r' in nmea_data,
            "contains_lf": '\n' in nmea_data,
            "contains_crlf": '\r\n' in nmea_data,
            "line_count_split_n": len(nmea_data.split('\n')),
            "line_count_split_rn": len(nmea_data.split('\r\n')),
            "first_3_lines": nmea_data.split('\n')[:3] if '\n' in nmea_data else ["No LF found"],
        }
        
    except Exception as e:
        return {"error": str(e)}


@app.get("/")
async def root():
    """Root endpoint"""
    return {
        "service": "GL.iNet GPS Streamer",
        "version": "1.0.0",
        "status": "running"
    }


if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=9999,
        log_level=LOG_LEVEL.lower(),
        access_log=True
    )