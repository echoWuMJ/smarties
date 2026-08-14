#include "NetworkAudit.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <iomanip>
#include <limits>
#include <locale>
#include <sstream>
#include <stdexcept>

namespace smarties
{
namespace
{

template<typename RealType, std::size_t Size = sizeof(RealType)>
struct FiniteBits;

template<typename RealType>
struct FiniteBits<RealType, sizeof(std::uint32_t)>
{
  static bool check(const RealType value)
  {
    std::uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return (bits & UINT32_C(0x7f800000)) != UINT32_C(0x7f800000);
  }
};

template<typename RealType>
struct FiniteBits<RealType, sizeof(std::uint64_t)>
{
  static bool check(const RealType value)
  {
    std::uint64_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return (bits & UINT64_C(0x7ff0000000000000)) !=
           UINT64_C(0x7ff0000000000000);
  }
};

bool isFiniteBits(const nnReal value)
{
  static_assert(sizeof(nnReal) == sizeof(std::uint32_t) ||
                sizeof(nnReal) == sizeof(std::uint64_t),
                "nnReal must use an IEEE binary32 or binary64 representation");
  return FiniteBits<nnReal>::check(value);
}

bool isValidLabel(const std::string& label)
{
  if (label.empty()) return false;
  return std::none_of(label.begin(), label.end(), [](const char value) {
    return std::isspace(static_cast<unsigned char>(value)) != 0;
  });
}

} // anonymous namespace

ParameterAudit auditParameters(const Parameters& parameters)
{
  ParameterAudit audit;
  audit.count = parameters.nParams;
  audit.precision_bytes = sizeof(nnReal);

  const unsigned char* const bytes =
    reinterpret_cast<const unsigned char*>(parameters.params);
  const std::size_t byte_count =
    static_cast<std::size_t>(parameters.nParams) * sizeof(nnReal);
  std::uint64_t digest = UINT64_C(0xcbf29ce484222325);
  for (std::size_t index = 0; index < byte_count; ++index) {
    digest ^= static_cast<std::uint64_t>(bytes[index]);
    digest *= UINT64_C(0x100000001b3);
  }
  audit.digest = digest;

  for (Uint index = 0; index < parameters.nParams; ++index) {
    const nnReal value = parameters.params[index];
    audit.finite = audit.finite && isFiniteBits(value);
    const long double wide = static_cast<long double>(value);
    audit.sum += wide;
    audit.sum_squares += wide * wide;
    audit.max_abs = std::max(audit.max_abs, std::fabs(wide));
  }
  return audit;
}

std::string formatParameterAudit(const std::string& stage,
                                 const std::string& network,
                                 const Uint optimizer_step,
                                 const Uint threads,
                                 const ParameterAudit& audit)
{
  if (!isValidLabel(stage))
    throw std::invalid_argument("network audit stage must be nonempty and contain no whitespace");
  if (!isValidLabel(network))
    throw std::invalid_argument("network audit name must be nonempty and contain no whitespace");

  std::ostringstream output;
  output.imbue(std::locale::classic());
  output << "SMARTIES_NETWORK_AUDIT"
         << " stage=" << stage
         << " network=" << network
         << " step=" << optimizer_step
         << " threads=" << threads
         << " precision_bytes=" << audit.precision_bytes
         << " params=" << audit.count
         << " digest=" << std::hex << std::setw(16) << std::setfill('0')
         << audit.digest << std::dec << std::setfill(' ')
         << std::scientific
         << std::setprecision(std::numeric_limits<long double>::max_digits10)
         << " sum=" << audit.sum
         << " sum_squares=" << audit.sum_squares
         << " max_abs=" << audit.max_abs
         << " finite=" << (audit.finite ? 1 : 0);
  return output.str();
}

} // namespace smarties
