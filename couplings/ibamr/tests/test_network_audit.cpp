#include "smarties/Network/NetworkAudit.h"

#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

int main()
{
  using smarties::Parameters;
  using smarties::Uint;
  using smarties::nnReal;

  Parameters parameters({4}, {0}, 1);
  parameters.clear();
  parameters.params[0] = nnReal(1.0);
  parameters.params[1] = nnReal(-2.0);
  parameters.params[2] = nnReal(3.5);
  parameters.params[3] = nnReal(4.25);

  const auto first = smarties::auditParameters(parameters);
  if (!first.finite || first.count != parameters.nParams) return 1;
  if (first.precision_bytes != sizeof(nnReal)) return 2;

  const std::uint64_t expected_digest = sizeof(nnReal) == 4
    ? UINT64_C(0xa572d5b7c223c3f0)
    : UINT64_C(0xacc1f57cf90c1eed);
  if (first.digest != expected_digest) return 3;

  const auto repeated = smarties::auditParameters(parameters);
  if (repeated.digest != first.digest) return 4;

  parameters.params[2] = std::nextafter(parameters.params[2], nnReal(9));
  const auto changed = smarties::auditParameters(parameters);
  if (changed.digest == first.digest) return 5;

  parameters.params[1] = std::numeric_limits<nnReal>::infinity();
  if (smarties::auditParameters(parameters).finite) return 6;

  parameters.params[1] = nnReal(-2.0);
  parameters.params[2] = nnReal(3.5);
  const std::string record = smarties::formatParameterAudit(
    "initialized", "policy", Uint(0), Uint(4),
    smarties::auditParameters(parameters));
  if (record.find("SMARTIES_NETWORK_AUDIT stage=initialized network=policy ") != 0)
    return 7;
  if (record.find(" finite=1") == std::string::npos) return 8;

  bool rejected_stage = false;
  try {
    (void)smarties::formatParameterAudit(
      "bad stage", "policy", Uint(0), Uint(1), first);
  } catch (const std::invalid_argument&) {
    rejected_stage = true;
  }
  if (!rejected_stage) return 9;

  bool rejected_network = false;
  try {
    (void)smarties::formatParameterAudit(
      "update", "bad network", Uint(1), Uint(1), first);
  } catch (const std::invalid_argument&) {
    rejected_network = true;
  }
  return rejected_network ? 0 : 10;
}
