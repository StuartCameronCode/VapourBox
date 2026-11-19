"""Test-only: widen vspipe R78's teardown race window so it fires on demand.

outputFrame() sleeps 20 ms before writing (the callback is mid-write for
longer), and outputNode() sleeps 5 ms between requesting the frames and
checking its wait predicate (main is "descheduled", as under CPU load). With
R78's count-at-entry the predicate is then already true while the callback is
still writing; with the fix the count only moves after the write.
"""
import sys
p = sys.argv[1]
s = open(p).read()
old = 'static void outputFrame(const VSFrame *frame, VSPipeOutputData *data) {\n'
assert s.count(old) == 1
s = s.replace(old, old + '    std::this_thread::sleep_for(std::chrono::milliseconds(20)); /* TEST ONLY */\n')
old = '    data->condition.wait(lock, [&]() {'
assert s.count(old) == 1
s = s.replace(old, '    std::this_thread::sleep_for(std::chrono::milliseconds(5)); /* TEST ONLY */\n' + old)
s = s.replace('#include <chrono>\n', '#include <chrono>\n#include <thread>\n', 1)
open(p, 'w').write(s)
