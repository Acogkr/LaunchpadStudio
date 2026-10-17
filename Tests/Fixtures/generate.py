#!/usr/bin/env python3
"""Create synthetic Launchpad records. No installed apps or user paths are read."""
import pathlib
import sqlite3
import sys

destination = pathlib.Path(sys.argv[1])
if destination.exists():
    raise SystemExit(f"Refusing to replace an existing fixture: {destination}")
destination.parent.mkdir(parents=True, exist_ok=True)
db = sqlite3.connect(destination)
db.executescript(pathlib.Path(__file__).with_name('schema.sql').read_text())
db.executemany('INSERT INTO dbinfo VALUES (?,?)', [
    ('version', '13'), ('compatibleVersion', '6'),
    ('ignore_items_update_triggers', '1'), ('launchpad_root', '1'),
])

def item(identifier, uuid, kind, parent, order):
    db.execute('INSERT INTO items VALUES (?,?,?,?,?,?)', (identifier, uuid, 0, kind, parent, order))

item(1, 'ROOT', 1, 0, 0)
item(2, 'HOLDINGPAGE', 3, 1, 0)
item(3, 'PAGE-A', 3, 1, 1)
item(4, 'PAGE-B', 3, 1, 2)
item(5, 'FOLDER-A', 2, 3, 0)
item(6, 'FOLDER-A-PAGE-1', 3, 5, 0)
item(7, 'FOLDER-A-PAGE-2', 3, 5, 1)
item(8, 'FOLDER-B', 2, 3, 1)
item(9, 'FOLDER-B-PAGE-1', 3, 8, 0)
item(10, 'UNRELATED-ROOT', 1, 0, 0)
db.executemany('INSERT INTO groups VALUES (?,NULL,?)', [(3, None), (4, None), (5, 'Work'), (6, None), (7, None), (8, 'Personal'), (9, None)])
categories = ['utilities', 'productivity', 'developer-tools', 'music', 'graphics-design', 'games', 'video', 'social-networking']
db.executemany('INSERT INTO categories VALUES (?,?)', [(i + 1, 'public.app-category.' + value) for i, value in enumerate(categories)])
for i in range(98):
    parent, order = (6, i) if i < 20 else (7, i - 20) if i < 40 else (9, i - 40) if i < 70 else (4, i - 70)
    identifier = 1000 + i
    item(identifier, f'FIXTURE-APP-{i:03}', 4, parent, order)
    title, bundle = f'Sample App {i + 1}', f'org.example.launchpad-fixture.app{i + 1}'
    if i == 97:
        title, bundle = 'Launchpad Studio', 'local.launchpadstudio.app'
    db.execute('INSERT INTO apps VALUES (?,?,?,NULL,?,?,?)', (identifier, title, bundle, i % len(categories) + 1, 0.0, b'synthetic-bookmark'))
    db.execute('UPDATE image_cache SET image_data=?,image_data_mini=? WHERE item_id=?', (b'synthetic-icon', b'synthetic-mini', identifier))
item(2000, 'HIDDEN-APP', 4, 2, 0)
db.execute("INSERT INTO apps VALUES (2000,'Hidden Fixture','org.example.hidden',NULL,1,0,NULL)")
db.execute("UPDATE dbinfo SET value='0' WHERE key='ignore_items_update_triggers'")
db.commit()
assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
db.close()
