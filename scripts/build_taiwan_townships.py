#!/usr/bin/env python3
"""Build the display-only township map from the pinned official NLSC archive.

Requires Python 3, curl, Node.js and npm. Mapshaper is fetched at its pinned version
into npm's cache, never into the app's dependencies. Pass --archive for offline
rebuilds after caching the official ZIP. The SHA256 check deliberately fails if
the upstream ZIP changes: inspect its source/version before updating the pin.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import tempfile
import urllib.parse
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE_URL = (
    'https://www.tgos.tw/tgos/VirtualDir/Product/'
    '3fe61d4a-ca23-4f45-8aca-4a536f40f290/'
    + urllib.parse.quote('鄉(鎮、市、區)界線1140318.zip', safe='')
)
SOURCE_SHA256 = 'c5dc6c0f9a8cc1aad6758a0a6fb81b203718b37f42c5aa8e684262ca24a7d9dd'
SOURCE_VERSION = 'TOWN_MOI_1140318'
MAPSHAPER_VERSION = '0.7.61'
RETRIEVED_AT = '2026-09-15'
ATTRIBUTION = (
    '內政部國土測繪中心 2025 鄉鎮市區界線（1140318）。'
    '此開放資料依政府資料開放授權條款第1版進行公眾釋出；'
    '本圖經簡化，僅供資訊顯示，非法律或測量界線依據。'
)


def run(*args: str) -> None:
    subprocess.run(args, check=True)


def convert(directory: Path, basename: str, output: Path) -> dict:
    run(
        'npm', 'exec', '--yes', f'--package=mapshaper@{MAPSHAPER_VERSION}', '--',
        'mapshaper', str(directory / f'{basename}.shp'), 'encoding=utf8',
        '-proj', 'wgs84',
        # Explode before keep-shapes so every offshore polygon, not just each
        # township's largest polygon, is protected from being simplified away.
        '-explode', '-simplify', 'dp', 'interval=50m', 'keep-shapes', 'stats',
        '-dissolve', 'TOWNCODE', 'copy-fields=COUNTYNAME,TOWNNAME,COUNTYCODE',
        '-rename-fields',
        'county=COUNTYNAME,district=TOWNNAME,townCode=TOWNCODE,countyCode=COUNTYCODE',
        '-o', 'format=geojson', 'precision=0.000001', 'fix-geometry', str(output),
    )
    return json.loads(output.read_text(encoding='utf-8'))


def normalize_features(collection: dict) -> list[dict]:
    result = []
    for feature in collection['features']:
        properties = feature['properties']
        assert set(properties) == {'county', 'district', 'townCode', 'countyCode'}
        assert isinstance(properties['townCode'], str) and len(properties['townCode']) == 8
        assert isinstance(properties['countyCode'], str) and len(properties['countyCode']) == 5
        assert properties['townCode'].startswith(properties['countyCode'])
        geometry = feature['geometry']
        assert geometry['type'] in {'Polygon', 'MultiPolygon'}
        polygons = geometry['coordinates'] if geometry['type'] == 'MultiPolygon' else [geometry['coordinates']]
        assert polygons
        for polygon in polygons:
            assert polygon
            for ring in polygon:
                assert len(ring) >= 4 and ring[0] == ring[-1]
                assert len({tuple(point) for point in ring[:-1]}) >= 3
                for point in ring:
                    assert len(point) == 2 and all(math.isfinite(value) for value in point)
                    assert 114 <= point[0] <= 125 and 10 <= point[1] <= 27
        result.append({
            'type': 'Feature', 'id': properties['townCode'], 'properties': properties,
            'geometry': {'type': 'MultiPolygon', 'coordinates': polygons},
        })
    return sorted(result, key=lambda feature: feature['properties']['townCode'])


def validate_catalog(features: list[dict]) -> dict:
    catalog = json.loads((ROOT / 'RainyClock/Resources/taiwan-districts.json').read_text())
    expected = {(entry['county'], entry['district']) for entry in catalog}
    actual = {(entry['properties']['county'], entry['properties']['district']) for entry in features}
    assert len(features) == len(actual) == len(expected) == 368
    assert actual == expected, f'Catalog mismatch: missing={expected - actual}, extra={actual - expected}'
    assert len({entry['properties']['townCode'] for entry in features}) == 368
    assert len({entry['properties']['county'] for entry in features}) == 22
    assert len({entry['properties']['countyCode'] for entry in features}) == 22
    # Check commonly overlooked offshore coverage and representative shared
    # boundaries after GeoJSON expansion/rounding.
    for entry in [('金門縣', '烏坵鄉'), ('連江縣', '南竿鄉'), ('連江縣', '北竿鄉'),
                  ('連江縣', '莒光鄉'), ('連江縣', '東引鄉'), ('臺東縣', '綠島鄉'),
                  ('臺東縣', '蘭嶼鄉'), ('屏東縣', '琉球鄉')]:
        assert entry in actual
    edge_owners: dict[tuple, set[str]] = {}
    positions = 0
    for feature in features:
        name = feature['properties']['county'] + feature['properties']['district']
        for polygon in feature['geometry']['coordinates']:
            for ring in polygon:
                positions += len(ring)
                for start, end in zip(ring, ring[1:]):
                    edge = tuple(sorted((tuple(start), tuple(end))))
                    edge_owners.setdefault(edge, set()).add(name)
    neighbors = set()
    shared_edges = 0
    for owners in edge_owners.values():
        if len(owners) == 2:
            neighbors.add(tuple(sorted(owners)))
            shared_edges += 1
    for pair in [('臺北市中正區', '臺北市萬華區'), ('臺中市北區', '臺中市西區'),
                 ('新北市板橋區', '新北市中和區')]:
        assert tuple(sorted(pair)) in neighbors, f'Shared boundary missing: {pair}'
    assert shared_edges > 1000 and len(neighbors) > 500
    return {
        'townships': len(features), 'counties': 22, 'coordinatePositions': positions,
        'polygonParts': sum(len(feature['geometry']['coordinates']) for feature in features),
        'sharedEdges': shared_edges, 'adjacentTownshipPairs': len(neighbors),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='Previously downloaded official ZIP; still hash-checked')
    parser.add_argument('--output', type=Path, default=ROOT / 'RainyClock/Resources/taiwan-townships.geojson')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='rainyclock-townships-') as temporary:
        directory = Path(temporary)
        archive = args.archive
        if archive is None:
            archive = directory / 'source.zip'
            run('curl', '--fail', '--location', '--proto', '=https', '--max-time', '60',
                '--max-filesize', str(20 * 1024 * 1024), '--output', str(archive), SOURCE_URL)
        source = archive.read_bytes()
        assert hashlib.sha256(source).hexdigest() == SOURCE_SHA256, 'Official ZIP changed; inspect before updating this source pin'
        with zipfile.ZipFile(archive) as content:
            # Extract only exact expected files; never extract arbitrary ZIP paths.
            for basename in [SOURCE_VERSION, 'Town_Majia_Sanhe']:
                for extension in ['shp', 'shx', 'dbf', 'prj', 'CPG']:
                    name = f'{basename}.{extension}'
                    (directory / name).write_bytes(content.read(name))
        features = normalize_features(convert(directory, SOURCE_VERSION, directory / 'main.geojson'))
        supplemental = normalize_features(convert(directory, 'Town_Majia_Sanhe', directory / 'supplement.geojson'))
        assert len(supplemental) == 1 and supplemental[0]['properties']['townCode'] == '10013280'
        stats = validate_catalog(features)
        result = {
            'type': 'FeatureCollection',
            'name': 'taiwan-townships',
            'source': {
                'agency': '內政部國土測繪中心', 'dataset': 'https://data.gov.tw/dataset/7441',
                'url': SOURCE_URL, 'version': SOURCE_VERSION, 'retrievedAt': RETRIEVED_AT,
                'archiveSHA256': SOURCE_SHA256, 'license': 'https://data.gov.tw/license',
                'attribution': ATTRIBUTION,
                'sourceCRS': 'TWD97[2020] geographic / GRS80',
                'displayCRS': 'WGS84 longitude/latitude (generalized display)',
                'simplification': f'Mapshaper {MAPSHAPER_VERSION}; shared topology; spherical RDP 50m; keep all polygon parts; 0.000001-degree output precision',
            },
            'features': features,
            # Kept separate because the official archive supplies this as an
            # overlapping administrative grouping, not part of the main partition.
            'supplementalFeatures': supplemental,
        }
        encoded = (json.dumps(result, ensure_ascii=False, separators=(',', ':')) + '\n').encode()
        assert len(encoded) <= 1_500_000, f'Output exceeds map resource budget: {len(encoded)}'
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(encoded)
        print(json.dumps({**stats, 'bytes': len(encoded), 'sha256': hashlib.sha256(encoded).hexdigest()}, indent=2))


if __name__ == '__main__':
    main()
