#ifndef smarties_NetworkAudit_h
#define smarties_NetworkAudit_h

#include "Layers/Parameters.h"

#include <cstddef>
#include <cstdint>
#include <string>

namespace smarties
{

struct ParameterAudit
{
  Uint count = 0;
  std::uint64_t digest = 0;
  long double sum = 0;
  long double sum_squares = 0;
  long double max_abs = 0;
  bool finite = true;
  std::size_t precision_bytes = 0;
};

ParameterAudit auditParameters(const Parameters& parameters);

std::string formatParameterAudit(const std::string& stage,
                                 const std::string& network,
                                 Uint optimizer_step,
                                 Uint threads,
                                 const ParameterAudit& audit);

} // namespace smarties

#endif // smarties_NetworkAudit_h
