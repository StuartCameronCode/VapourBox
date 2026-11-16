"""B, the frame count: what the index alone says the length is, against the
untrimmed decode (the app's count, which tasks #24/#26 made exact).

  packets       video packets (pictures, or fields on a field-coded source)
  index count   grid sources: the last picture's fps-filter slot + 1;
                otherwise: packets (one picture each)
Writes data/count.json.
"""
import json
import os

import pktlib as L


def main():
    rows = []
    for name in L.SEEK_SUITE + L.GRID_SUITE:
        info = L.source_info(L.resource(name))
        idx, tb = L.packet_index(info['path'])
        decoded = len(L.reference(info)['seq'])
        pts = [p['pts'] for p in idx if p['pts'] is not None]
        if info['grid']:
            count = L.fps_slot(max(pts), tb, info['grid']) + 1
            how = 'last slot + 1'
        else:
            count = len(idx)
            how = 'packets'
        rows.append(dict(fixture=name, decoded=decoded, packets=len(idx), packets_without_pts=len(idx) - len(pts),
                         index_count=count, how=how, agrees=count == decoded))
        print(f'{name:30s} decoded {decoded:5d}  packets {len(idx):5d}  index {count:5d} ({how})'
              f'{"" if count == decoded else "  DIFFERS"}')
    json.dump(rows, open(os.path.join(L.DATA, 'count.json'), 'w'), indent=1)


if __name__ == '__main__':
    main()
