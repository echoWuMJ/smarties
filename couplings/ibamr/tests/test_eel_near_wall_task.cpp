#include "EelNearWallTask.h"
#include <cmath>
#include <iostream>
#include <stdexcept>

int main()
{
  using namespace ibamr_smarties::eel2d;
  NearWallConfig c;
  c.validate();
  NearWallObservation o;
  o.height = 0.4;
  o.minimum_gap = 0.3;
  if (nearWallEnd(o, c) != NearWallEnd::running) return 1;
  o.height = 0.7;
  if (nearWallEnd(o, c) != NearWallEnd::escaped) return 2;
  o.minimum_gap = 0;
  if (nearWallEnd(o, c) != NearWallEnd::collision) return 3;
  o.minimum_gap = 0.2;
  o.height = 0.4;
  o.progress = 4;
  if (nearWallEnd(o, c) != NearWallEnd::goal) return 4;
  o.outside_safe_domain = true;
  if (nearWallEnd(o, c) != NearWallEnd::domain_limit) return 5;
  if (nearWallIsTerminal(NearWallEnd::time_limit) ||
      !nearWallIsTerminal(NearWallEnd::collision)) return 6;
  const double scale = 0.5*c.density*c.referenceSpeed()*c.referenceSpeed()*c.length;
  if (std::abs(nearWallForceCoefficient(-scale, c)-1.0) > 1e-12) return 7;
  // Half a control interval must carry half the impulse, not be normalized
  // back into a full interval. A collision penalty is applied once.
  if (std::abs(nearWallReward(-scale*c.controlInterval()/2,
                              NearWallEnd::collision, c)+0.5) > 1e-12) return 8;
  o.velocity = {{-c.referenceSpeed(), 0.0}};
  for (auto& u : o.fluid_velocity) u = o.velocity;
  const auto s = makeNearWallState(o, c);
  if (s.size() != 25 || std::abs(s[2]-1) > 1e-12 || s[5] != 1) return 9;
  for (unsigned i=11; i<23; ++i) if (s[i] != 0) return 10;
  c.initial_height_max = 0.7;
  try { c.validate(); return 11; } catch (const std::invalid_argument&) {}
  std::cout << "near-wall task: terminal priority, force sign, partial impulse and 25D state passed\n";
}
