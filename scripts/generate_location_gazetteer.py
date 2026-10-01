#!/usr/bin/env python3
"""Build the compact on-device location gazetteer used by Memorable.

Inputs are the countries+states+cities JSON export from
dr5hn/countries-states-cities-database v3.1-export.2 (ODbL-1.0) and the
Natural Earth admin-0/admin-1 GeoJSON files (public domain).
"""

from __future__ import annotations

import argparse
import gzip
import json
import math
import sqlite3
import unicodedata
from pathlib import Path


def normalized(value: str | None) -> str:
    if not value:
        return ""
    decomposed = unicodedata.normalize("NFKD", value)
    without_marks = "".join(character for character in decomposed if not unicodedata.combining(character))
    return " ".join(without_marks.casefold().split())


def coordinate(value: object) -> float | None:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None


def longitude_bounds(longitudes: list[float], padding: float) -> tuple[float, float]:
    normalized_longitudes = sorted((longitude % 360) for longitude in longitudes)
    if len(normalized_longitudes) == 1:
        west = normalized_longitudes[0] - padding
        east = normalized_longitudes[0] + padding
    else:
        gaps = [
            (normalized_longitudes[(index + 1) % len(normalized_longitudes)]
             - normalized_longitudes[index]) % 360
            for index in range(len(normalized_longitudes))
        ]
        gap_index = max(range(len(gaps)), key=gaps.__getitem__)
        west = normalized_longitudes[(gap_index + 1) % len(normalized_longitudes)] - padding
        east = normalized_longitudes[gap_index] + padding

    def signed(value: float) -> float:
        return ((value + 180) % 360) - 180

    return signed(west), signed(east)


def bounds(points: list[tuple[float, float]], fallback: tuple[float, float], padding: float) -> list[float]:
    usable = points or [fallback]
    latitudes = [point[0] for point in usable]
    longitudes = [point[1] for point in usable]
    south = max(-90, min(latitudes) - padding)
    north = min(90, max(latitudes) + padding)
    west, east = longitude_bounds(longitudes, padding)
    return [round(south, 4), round(west, 4), round(north, 4), round(east, 4)]


def load_json(path: Path) -> object:
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8") as handle:
        return json.load(handle)


def point_line_distance(point: list[float], start: list[float], end: list[float]) -> float:
    delta_x = end[0] - start[0]
    delta_y = end[1] - start[1]
    if delta_x == 0 and delta_y == 0:
        return math.hypot(point[0] - start[0], point[1] - start[1])
    numerator = abs(
        delta_y * point[0] - delta_x * point[1]
        + end[0] * start[1] - end[1] * start[0]
    )
    return numerator / math.hypot(delta_x, delta_y)


def simplify_line(points: list[list[float]], tolerance: float) -> list[list[float]]:
    if len(points) <= 2:
        return points
    distances = [
        point_line_distance(point, points[0], points[-1])
        for point in points[1:-1]
    ]
    if not distances or max(distances) <= tolerance:
        return [points[0], points[-1]]
    split = distances.index(max(distances)) + 1
    return simplify_line(points[:split + 1], tolerance)[:-1] + simplify_line(points[split:], tolerance)


def simplify_ring(ring: list[list[float]], tolerance: float) -> list[list[float]]:
    points = ring[:-1] if ring and ring[0] == ring[-1] else ring
    if len(points) < 4:
        return ring
    split = max(
        range(1, len(points)),
        key=lambda index: math.hypot(
            points[index][0] - points[0][0],
            points[index][1] - points[0][1],
        ),
    )
    simplified = (
        simplify_line(points[:split + 1], tolerance)[:-1]
        + simplify_line(points[split:] + [points[0]], tolerance)
    )
    if len(simplified) < 4:
        return ring
    return [[round(point[0], 4), round(point[1], 4)] for point in simplified]


def polygon_coordinates(
    geometry: dict[str, object] | None,
    simplification_tolerance: float = 0,
) -> list[object] | None:
    if not geometry:
        return None
    geometry_type = geometry.get("type")
    coordinates = geometry.get("coordinates")
    if geometry_type == "Polygon":
        polygons = [coordinates]
    elif geometry_type == "MultiPolygon":
        polygons = coordinates
    else:
        return None
    if simplification_tolerance <= 0:
        return polygons
    return [
        [simplify_ring(ring, simplification_tolerance) for ring in polygon]
        for polygon in polygons
    ]


def geometry_bounds(polygons: list[object]) -> list[float]:
    points = [
        (float(point[1]), float(point[0]))
        for polygon in polygons
        for ring in polygon
        for point in ring
    ]
    return bounds(points, points[0], padding=0.02)


def normalized_code(value: object) -> str:
    return normalized(value if isinstance(value, str) else None)


def load_admin_boundaries(path: Path) -> tuple[dict[tuple[str, str], list[object]], dict[tuple[str, str], list[object]]]:
    by_code: dict[tuple[str, str], list[object]] = {}
    by_name: dict[tuple[str, str], list[object]] = {}
    for feature in load_json(path)["features"]:
        properties = feature["properties"]
        country_code = normalized_code(properties.get("iso_a2"))
        polygons = polygon_coordinates(
            feature.get("geometry"),
            simplification_tolerance=0.02,
        )
        if len(country_code) != 2 or not polygons:
            continue
        codes = {
            normalized_code(properties.get("postal")),
            normalized_code(properties.get("iso_3166_2", "").split("-")[-1]),
        }
        for code in codes - {""}:
            by_code[(country_code, code)] = polygons
        name = normalized(properties.get("name"))
        if name:
            by_name[(country_code, name)] = polygons
    return by_code, by_name


def load_country_boundaries(path: Path) -> dict[str, list[object]]:
    result: dict[str, list[object]] = {}
    for feature in load_json(path)["features"]:
        properties = feature["properties"]
        country_code = normalized_code(properties.get("ISO_A2_EH"))
        if len(country_code) != 2:
            country_code = normalized_code(properties.get("ISO_A2"))
        polygons = polygon_coordinates(feature.get("geometry"))
        if len(country_code) == 2 and polygons:
            result[country_code] = polygons
    return result


def load_city_prominence(path: Path) -> dict[tuple[str, str], int]:
    result: dict[tuple[str, str], int] = {}
    for feature in load_json(path)["features"]:
        properties = feature["properties"]
        country_code = normalized_code(properties.get("ISO_A2"))
        name = normalized(properties.get("NAME"))
        population = int(coordinate(properties.get("POP_MAX")) or 0)
        if len(country_code) != 2 or not name or population <= 0:
            continue
        key = (country_code, name)
        result[key] = max(result.get(key, 0), population)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--resources", type=Path, default=Path("Memorable/Resources"))
    parser.add_argument("--admin-boundaries", type=Path, required=True)
    parser.add_argument("--country-boundaries", type=Path, required=True)
    parser.add_argument("--populated-places", type=Path, required=True)
    args = parser.parse_args()

    known_names: set[str] = set()
    for filename in ("known_cities.json", "known_multiword_locations.json"):
        values = load_json(args.resources / filename)
        known_names.update(normalized(value) for value in values)

    countries = load_json(args.source)
    admin_boundaries_by_code, admin_boundaries_by_name = load_admin_boundaries(args.admin_boundaries)
    country_boundaries = load_country_boundaries(args.country_boundaries)
    city_prominence = load_city_prominence(args.populated_places)
    records: list[dict[str, object]] = []
    aliases: dict[str, str] = {}
    for country in countries:
        country_name = normalized(country.get("name"))
        country_code = normalized_code(country.get("iso2"))
        country_code3 = normalized_code(country.get("iso3"))
        if country_name:
            for alias in (country_code, country_code3):
                if alias:
                    aliases[alias] = country_name
        capital_name = normalized(country.get("capital"))
        country_geometry = country_boundaries.get(country_code)
        records.append({
            "n": country_name,
            "k": "o",
            "c": country_name,
            "g": country_geometry,
            "b": geometry_bounds(country_geometry) if country_geometry else None,
        })

        for state in country.get("states", []):
            state_name = normalized(state.get("name"))
            state_code = normalized(state.get("iso2"))
            state_latitude = coordinate(state.get("latitude"))
            state_longitude = coordinate(state.get("longitude"))
            city_points: list[tuple[float, float]] = []

            for city in state.get("cities", []):
                city_name = normalized(city.get("name"))
                latitude = coordinate(city.get("latitude"))
                longitude = coordinate(city.get("longitude"))
                if latitude is None or longitude is None:
                    continue
                city_points.append((latitude, longitude))
                if city_name not in known_names:
                    continue
                records.append({
                    "n": city_name,
                    "k": "c",
                    "c": country_name,
                    "a": state_name,
                    "x": round(latitude, 5),
                    "y": round(longitude, 5),
                    "p": city_name == capital_name,
                    "r": city_prominence.get((country_code, city_name), 0),
                })

            if not state_name or state_latitude is None or state_longitude is None:
                continue
            state_geometry = admin_boundaries_by_code.get((country_code, state_code))
            if state_geometry is None:
                state_geometry = admin_boundaries_by_name.get((country_code, state_name))
            records.append({
                "n": state_name,
                "k": "a",
                "c": country_name,
                "o": state_code,
                "b": geometry_bounds(state_geometry) if state_geometry else bounds(
                    city_points,
                    (state_latitude, state_longitude),
                    padding=0.35,
                ),
                "g": state_geometry,
            })

    records.sort(key=lambda record: (str(record["n"]), str(record["k"]), str(record.get("c", ""))))
    aliases.update({
        "u s": "united states",
        "u s a": "united states",
        "u k": "united kingdom",
        "uae": "united arab emirates",
    })
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.unlink(missing_ok=True)
    connection = sqlite3.connect(args.output)
    try:
        connection.executescript("""
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            CREATE TABLE locations (
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                country TEXT NOT NULL,
                admin TEXT,
                code TEXT,
                latitude REAL,
                longitude REAL,
                isCapital INTEGER NOT NULL DEFAULT 0,
                prominence INTEGER NOT NULL DEFAULT 0,
                south REAL,
                west REAL,
                north REAL,
                east REAL
                ,geometry TEXT
            );
            CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
        connection.executemany(
            """
                INSERT INTO locations (
                    name, kind, country, admin, code, latitude, longitude,
                    isCapital, prominence, south, west, north, east, geometry
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    record["n"], record["k"], record["c"], record.get("a"),
                    record.get("o"), record.get("x"), record.get("y"),
                    int(bool(record.get("p"))),
                    int(record.get("r", 0)),
                    *(record.get("b") or [None, None, None, None]),
                    json.dumps(record.get("g"), separators=(",", ":")) if record.get("g") else None,
                )
                for record in records
            ],
        )
        connection.execute("CREATE TABLE aliases (alias TEXT PRIMARY KEY, target TEXT NOT NULL)")
        connection.executemany(
            "INSERT INTO aliases (alias, target) VALUES (?, ?)",
            sorted(aliases.items()),
        )
        connection.executemany(
            "INSERT INTO metadata (key, value) VALUES (?, ?)",
            [
                ("formatVersion", "2"),
                ("source", "dr5hn/countries-states-cities-database"),
                ("sourceVersion", "v3.1-export.2"),
                ("license", "ODbL-1.0"),
                ("boundarySource", "Natural Earth 1:50m admin-0 / 1:10m admin-1"),
                ("boundaryLicense", "Public Domain"),
            ],
        )
        connection.executescript("""
            CREATE INDEX idx_locations_name ON locations(name, kind);
            CREATE INDEX idx_locations_code ON locations(code, kind);
            VACUUM;
        """)
    finally:
        connection.close()
    print(f"Wrote {len(records):,} records to {args.output}")


if __name__ == "__main__":
    main()
