#!/usr/bin/env python3
"""Zet een nieuwe versie bovenaan apps.json (SideStore/AltStore-bron). Houdt de laatste 10 versies."""
import json, sys, datetime
version, build, url, size, notes = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
src = json.load(open('apps.json'))
app = src['apps'][0]
v = {
    'version': version, 'buildVersion': build,
    'date': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'localizedDescription': notes or f'Versie {version}', 'downloadURL': url, 'size': size, 'minOSVersion': '15.0',
}
app['versions'] = [v] + [x for x in app.get('versions', []) if x.get('version') != version][:9]
# oude velden (AltStore 1.x) ook bijwerken
app.update({'version': version, 'versionDate': v['date'], 'versionDescription': v['localizedDescription'], 'downloadURL': url, 'size': size})
json.dump(src, open('apps.json', 'w'), indent=2, ensure_ascii=False)
open('apps.json', 'a').write('\n')
print(f'apps.json: {version} ({build})')
