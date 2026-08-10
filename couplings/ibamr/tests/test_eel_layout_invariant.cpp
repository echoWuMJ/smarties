#include "EelLayoutInvariant.h"

#include <array>
#include <stdexcept>
#include <string>

namespace
{
bool rejects(const std::size_t layout_points,
             const std::size_t lagrangian_points,
             const std::string& expected_layout,
             const std::string& expected_lagrangian)
{
  try
  {
    ibamr_smarties::eel2d::requireEelLayoutPointCount(
      layout_points, lagrangian_points, { { 0.03125, 0.03125 } });
  }
  catch (const std::invalid_argument& error)
  {
    const std::string message(error.what());
    return message.find(expected_layout) != std::string::npos &&
           message.find(expected_lagrangian) != std::string::npos &&
           message.find("0.03125") != std::string::npos;
  }
  return false;
}
} // namespace

int main()
{
  ibamr_smarties::eel2d::requireEelLayoutPointCount(
    2932, 2932, { { 0.00390625, 0.00390625 } });
  if (!rejects(76, 2932, "76", "2932")) return 1;
  if (!rejects(11232, 2932, "11232", "2932")) return 2;
  return 0;
}
