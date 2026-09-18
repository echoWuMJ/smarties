#ifdef NDEBUG
#undef NDEBUG
#endif
#include "PairedEpisodeState.h"
#include <cassert>
#include <sstream>
using namespace ibamr_smarties::eel2d;
int main() {
  ProxyRestart active{4,7,'A',0.37};
  auto copy=parseProxyRestart(serializeProxyRestart(active));
  assert(copy.episode==4 && copy.sequence==7 && copy.kind=='A' && copy.action==0.37);
  copy=parseProxyRestart(serializeProxyRestart({5,0,'N',0}));
  assert(copy.episode==5 && copy.kind=='N');
  for (const std::string s:{"1 0 7 A .3", "1 -1 7 A .3", "1 4 -2 A .3",
                           "1 4 0 A .3", "1 4 1 N 0", "1 4 1 T 0",
                           "1 4 1 A 1.1", "1 4 1 A 0 extra"}) {
    bool failed=false; try { parseProxyRestart(s); } catch(const std::exception&) { failed=true; }
    assert(failed);
  }
  CfdRestart state; state.height=.4; state.decisions=6; state.sequence=7;
  state.control={1.2,3}; state.probes.positions[0]={.2,.3}; state.probes.velocities[2]={-.1,.5};
  auto restored=parseCfdRestart(serializeCfdRestart(state));
  assert(restored.height==.4 && restored.decisions==6 && restored.sequence==7);
  assert(restored.control.applied_ratio==1.2 && restored.control.clipped_action_count==3);
  assert(restored.probes.positions==state.probes.positions && restored.probes.velocities==state.probes.velocities);
  bool failed=false; try { parseCfdRestart("1 .4 6 7 1.2 3"); } catch(const std::exception&) { failed=true; }
  assert(failed);
  for (const std::string s:{"1 .4 -1 7 1.2 3", "1 .4 6 -2 1.2 3",
                           "1 .4 6 7 1.2 -1"}) {
    failed=false; try { parseCfdRestart(s); } catch(const std::exception&) { failed=true; }
    assert(failed);
  }
}
