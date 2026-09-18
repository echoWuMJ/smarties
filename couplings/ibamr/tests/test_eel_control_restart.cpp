#include "TailBeatPhase.h"
#include "EelControlTask.h"
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>

using namespace ibamr_smarties::eel2d;
namespace {
void check(bool result, const char* message) {
  if (!result) throw std::runtime_error(message);
}
template<class F> void rejected(F f) {
  bool threw = false;
  try { f(); } catch (const std::invalid_argument&) { threw = true; }
  check(threw, "invalid checkpoint accepted");
}
}
int main() {
  try {
    TailBeatPhase live(6.28, 0.0), restored(6.28, 0.0);
    live.setFrequencyRatio(1.25, 0.4);
    live.setFrequencyRatio(0.75, 0.8);
    const auto phase = live.saveState();
    restored.restoreState(phase);
    check(std::abs(restored.valueAt(1.0) - 6.594) < 1e-13, "lost phase history");
    check(restored.frequencyRatio() == 0.75, "lost frequency");
    live.setFrequencyRatio(1.1, 1.0);
    restored.setFrequencyRatio(1.1, 1.0);
    check(restored.valueAt(1.2) == live.valueAt(1.2), "next phase differs");
    auto invalid = phase;
    invalid[0] = 6.29;
    rejected([&]{ restored.restoreState(invalid); });
    invalid = phase; invalid[1] = -1;
    rejected([&]{ restored.restoreState(invalid); });
    invalid = phase; invalid[2] = std::numeric_limits<double>::infinity();
    rejected([&]{ restored.restoreState(invalid); });
    invalid = phase; invalid[3] = 0;
    rejected([&]{ restored.restoreState(invalid); });
    check(restored.frequencyRatio() == 1.1, "bad restore mutated state");

    const EelTaskConfig config{6.28,0.5,1.5,0.1,8,0.2,-1,0,0.5,2,3,4,1,16};
    EelControlTask before(config), after(config);
    before.applyAction(2.0); // clips and raises 1.0 -> 1.1
    before.applyAction(1.0); // raises 1.1 -> 1.2
    const auto history = before.saveState();
    after.restoreState(history);
    const auto decision = after.applyAction(-1.0);
    check(std::abs(decision.previous_ratio-1.2) < 1e-13, "lost prior action");
    check(std::abs(decision.applied_ratio-1.1) < 1e-13, "limiter restarted at 1");
    check(after.clippedActionCount() == 1, "lost clipping count");
    check(decision.applied_ratio == before.applyAction(-1.0).applied_ratio, "next action differs");
    auto bad = history; bad.applied_ratio = 1.6;
    rejected([&]{ after.restoreState(bad); });
    bad.applied_ratio = std::numeric_limits<double>::quiet_NaN();
    rejected([&]{ after.restoreState(bad); });
    check(after.saveState().applied_ratio == decision.applied_ratio, "bad control restore mutated state");
    std::cout << "eel control restart passed\n";
    return 0;
  } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
