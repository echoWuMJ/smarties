#include "EelControlTask.h"

#include <algorithm>
#include <cerrno>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <map>
#include <set>
#include <stdexcept>

namespace ibamr_smarties
{
namespace eel2d
{
namespace
{
const double official_omega0 = 6.28;
const double pi = 3.1415926535897932384626433832795;

std::string trim(const std::string& text)
{
  std::size_t begin = 0;
  while (begin < text.size() && std::isspace(static_cast<unsigned char>(text[begin]))) ++begin;
  std::size_t end = text.size();
  while (end > begin && std::isspace(static_cast<unsigned char>(text[end - 1]))) --end;
  return text.substr(begin, end - begin);
}

double parseDouble(const std::string& text, const std::string& key)
{
  errno = 0;
  char* end = nullptr;
  const double value = std::strtod(text.c_str(), &end);
  if (errno != 0 || end == text.c_str() || *end != '\0' || !std::isfinite(value))
    throw std::invalid_argument("invalid finite number for " + key);
  return value;
}

unsigned parseUnsigned(const std::string& text, const std::string& key)
{
  if (text.empty() || text[0] == '-' || text[0] == '+')
    throw std::invalid_argument("invalid positive integer for " + key);
  errno = 0;
  char* end = nullptr;
  const unsigned long value = std::strtoul(text.c_str(), &end, 10);
  if (errno != 0 || end == text.c_str() || *end != '\0' || value == 0 ||
      value > std::numeric_limits<unsigned>::max())
    throw std::invalid_argument("invalid positive integer for " + key);
  return static_cast<unsigned>(value);
}

void validate(const EelTaskConfig& config)
{
  if (std::abs(config.baseline_angular_frequency - official_omega0) > 1.0e-12)
    throw std::invalid_argument("baseline_angular_frequency must preserve official value 6.28");
  if (config.minimum_frequency_ratio <= 0.0 ||
      config.maximum_frequency_ratio < config.minimum_frequency_ratio ||
      config.minimum_frequency_ratio > 1.0 || config.maximum_frequency_ratio < 1.0)
    throw std::invalid_argument("frequency ratio bounds must be positive and contain 1.0");
  if (config.maximum_ratio_delta <= 0.0)
    throw std::invalid_argument("maximum_ratio_delta must be positive");
  if (config.decisions_per_baseline_period == 0)
    throw std::invalid_argument("decisions_per_baseline_period must be positive");
  const double direction_norm = std::hypot(config.forward_direction_x,
                                            config.forward_direction_y);
  if (!std::isfinite(direction_norm) || std::abs(direction_norm - 1.0) > 1.0e-12)
    throw std::invalid_argument("forward direction must be a finite unit vector");
  if (config.velocity_scale <= 0.0)
    throw std::invalid_argument("velocity_scale must be positive");
  if (config.tracking_weight < 0.0 || config.frequency_weight < 0.0 ||
      config.smoothness_weight < 0.0)
    throw std::invalid_argument("reward weights must be nonnegative");
  if (config.warmup_cycles < 0.0)
    throw std::invalid_argument("warmup_cycles must be nonnegative");
  if (config.episode_decisions == 0)
    throw std::invalid_argument("episode_decisions must be positive");
}

const std::string& required(const std::map<std::string, std::string>& values,
                            const std::string& key)
{
  const auto found = values.find(key);
  if (found == values.end()) throw std::invalid_argument("missing required task key: " + key);
  return found->second;
}
} // namespace

EelTaskConfig
parseEelTaskConfig(std::istream& input)
{
  const std::set<std::string> allowed = {
    "baseline_angular_frequency", "minimum_frequency_ratio",
    "maximum_frequency_ratio", "maximum_ratio_delta",
    "decisions_per_baseline_period", "target_forward_speed",
    "forward_direction_x", "forward_direction_y", "velocity_scale",
    "tracking_weight", "frequency_weight", "smoothness_weight",
    "warmup_cycles", "episode_decisions"
  };
  std::map<std::string, std::string> values;
  std::string line;
  unsigned line_number = 0;
  while (std::getline(input, line))
  {
    ++line_number;
    const std::size_t comment = line.find('#');
    if (comment != std::string::npos) line.erase(comment);
    line = trim(line);
    if (line.empty()) continue;
    const std::size_t separator = line.find('=');
    if (separator == std::string::npos || line.find('=', separator + 1) != std::string::npos)
      throw std::invalid_argument("malformed task line " + std::to_string(line_number));
    const std::string key = trim(line.substr(0, separator));
    const std::string value = trim(line.substr(separator + 1));
    if (key.empty() || value.empty())
      throw std::invalid_argument("empty task key/value on line " + std::to_string(line_number));
    if (allowed.count(key) == 0) throw std::invalid_argument("unknown task key: " + key);
    if (!values.emplace(key, value).second) throw std::invalid_argument("duplicate task key: " + key);
  }

  EelTaskConfig config;
  config.baseline_angular_frequency =
    parseDouble(required(values, "baseline_angular_frequency"), "baseline_angular_frequency");
  config.minimum_frequency_ratio =
    parseDouble(required(values, "minimum_frequency_ratio"), "minimum_frequency_ratio");
  config.maximum_frequency_ratio =
    parseDouble(required(values, "maximum_frequency_ratio"), "maximum_frequency_ratio");
  config.maximum_ratio_delta =
    parseDouble(required(values, "maximum_ratio_delta"), "maximum_ratio_delta");
  config.decisions_per_baseline_period =
    parseUnsigned(required(values, "decisions_per_baseline_period"),
                  "decisions_per_baseline_period");
  config.target_forward_speed =
    parseDouble(required(values, "target_forward_speed"), "target_forward_speed");
  config.forward_direction_x =
    parseDouble(required(values, "forward_direction_x"), "forward_direction_x");
  config.forward_direction_y =
    parseDouble(required(values, "forward_direction_y"), "forward_direction_y");
  config.velocity_scale = parseDouble(required(values, "velocity_scale"), "velocity_scale");
  config.tracking_weight =
    parseDouble(required(values, "tracking_weight"), "tracking_weight");
  config.frequency_weight =
    parseDouble(required(values, "frequency_weight"), "frequency_weight");
  config.smoothness_weight =
    parseDouble(required(values, "smoothness_weight"), "smoothness_weight");
  config.warmup_cycles = parseDouble(required(values, "warmup_cycles"), "warmup_cycles");
  config.episode_decisions =
    parseUnsigned(required(values, "episode_decisions"), "episode_decisions");
  validate(config);
  return config;
}

EelTaskConfig
loadEelTaskConfig(const std::string& path)
{
  std::ifstream input(path);
  if (!input) throw std::runtime_error("cannot open eel task configuration: " + path);
  return parseEelTaskConfig(input);
}

EelControlTask::EelControlTask(EelTaskConfig config) : config_(config)
{
  validate(config_);
}

ControlDecision
EelControlTask::applyAction(const double action)
{
  if (!std::isfinite(action)) throw std::invalid_argument("eel action must be finite");
  const double clipped_action = std::max(-1.0, std::min(1.0, action));
  const bool clipped = clipped_action != action;
  if (clipped) ++clipped_action_count_;
  const double target = config_.minimum_frequency_ratio +
    0.5 * (clipped_action + 1.0) *
    (config_.maximum_frequency_ratio - config_.minimum_frequency_ratio);
  const double previous = applied_ratio_;
  const double delta = std::max(-config_.maximum_ratio_delta,
                                std::min(config_.maximum_ratio_delta,
                                         target - previous));
  applied_ratio_ = previous + delta;
  return { action, target, previous, applied_ratio_, clipped };
}

std::array<double, 5>
EelControlTask::makeState(const double forward_velocity, const double phase) const
{
  if (!std::isfinite(forward_velocity) || !std::isfinite(phase))
    throw std::invalid_argument("eel state inputs must be finite");
  return {{ forward_velocity / config_.velocity_scale,
            config_.target_forward_speed / config_.velocity_scale,
            applied_ratio_, std::sin(phase), std::cos(phase) }};
}

RewardBreakdown
EelControlTask::reward(const double forward_velocity, const double previous_ratio) const
{
  if (!std::isfinite(forward_velocity) || !std::isfinite(previous_ratio))
    throw std::invalid_argument("eel reward inputs must be finite");
  const double normalized_error =
    (forward_velocity - config_.target_forward_speed) / config_.velocity_scale;
  const double ratio_offset = applied_ratio_ - 1.0;
  const double ratio_change = applied_ratio_ - previous_ratio;
  RewardBreakdown result;
  result.tracking = -config_.tracking_weight * normalized_error * normalized_error;
  result.frequency = -config_.frequency_weight * ratio_offset * ratio_offset;
  result.smoothness = -config_.smoothness_weight * ratio_change * ratio_change;
  result.total = result.tracking + result.frequency + result.smoothness;
  return result;
}

double
EelControlTask::controlInterval() const
{
  return 2.0 * pi /
    (config_.decisions_per_baseline_period * config_.baseline_angular_frequency);
}

unsigned
EelControlTask::clippedActionCount() const
{
  return clipped_action_count_;
}

} // namespace eel2d
} // namespace ibamr_smarties
