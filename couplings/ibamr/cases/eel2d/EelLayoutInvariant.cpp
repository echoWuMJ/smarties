#include "EelLayoutInvariant.h"

#include <iomanip>
#include <sstream>
#include <stdexcept>

namespace ibamr_smarties
{
namespace eel2d
{
void requireEelLayoutPointCount(
  const std::size_t layout_points,
  const std::size_t lagrangian_points,
  const std::array<double, 2>& finest_mesh_width)
{
  if (layout_points == lagrangian_points) return;
  std::ostringstream message;
  message << std::setprecision(17)
          << "eel kinematics layout point count " << layout_points
          << " does not match Lagrangian vertex count " << lagrangian_points
          << " at finest mesh width (" << finest_mesh_width[0]
          << ", " << finest_mesh_width[1] << ')';
  throw std::invalid_argument(message.str());
}
} // namespace eel2d
} // namespace ibamr_smarties
