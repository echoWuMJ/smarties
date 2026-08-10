#ifndef included_ibamr_smarties_EelLayoutInvariant
#define included_ibamr_smarties_EelLayoutInvariant

#include <array>
#include <cstddef>

namespace ibamr_smarties
{
namespace eel2d
{
void requireEelLayoutPointCount(
  std::size_t layout_points,
  std::size_t lagrangian_points,
  const std::array<double, 2>& finest_mesh_width);
} // namespace eel2d
} // namespace ibamr_smarties

#endif
