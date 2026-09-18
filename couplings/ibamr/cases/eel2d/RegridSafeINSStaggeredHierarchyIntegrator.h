#pragma once

#include <ibamr/INSStaggeredHierarchyIntegrator.h>
#include <PatchHierarchy.h>
#include <PatchLevel.h>
#include <VariableDatabase.h>
#include <tbox/Utilities.h>

#include <vector>

namespace ibamr_smarties
{
namespace eel2d
{
// Case-side compatibility for IBAMR 0.18: regridding can release Div_U
// before regridProjection() uses it. Keep the library's projection unchanged.
class RegridSafeINSStaggeredHierarchyIntegrator
  : public IBAMR::INSStaggeredHierarchyIntegrator
{
public:
  using IBAMR::INSStaggeredHierarchyIntegrator::INSStaggeredHierarchyIntegrator;

protected:
  void regridProjection(const bool initial_time) override
  {
    auto* database = SAMRAI::hier::VariableDatabase<NDIM>::getDatabase();
    const auto divergence = database->getVariable(getName() + "::Div_U");
    if (divergence.isNull())
      TBOX_ERROR("Regrid compatibility: missing Div_U variable for " << getName() << "\n");
    const int index = database->mapVariableAndContextToIndex(divergence, getCurrentContext());
    if (index < 0)
      TBOX_ERROR("Regrid compatibility: missing Div_U current-context index\n");

    // Release only levels allocated here, including on a C++ exception.
    // Previously allocated data belong to IBAMR and must be preserved.
    struct Allocations
    {
      int index;
      std::vector<SAMRAI::tbox::Pointer<SAMRAI::hier::PatchLevel<NDIM>>> levels;
      ~Allocations()
      {
        for (const auto& level : levels) level->deallocatePatchData(index);
      }
    } allocations{index, {}};
    const auto hierarchy = getPatchHierarchy();
    allocations.levels.reserve(hierarchy->getFinestLevelNumber() + 1);
    for (int ln = 0; ln <= hierarchy->getFinestLevelNumber(); ++ln)
    {
      SAMRAI::tbox::Pointer<SAMRAI::hier::PatchLevel<NDIM>> level = hierarchy->getPatchLevel(ln);
      if (!level->checkAllocated(index))
      {
        level->allocatePatchData(index, getIntegratorTime());
        allocations.levels.push_back(level);
      }
    }
    IBAMR::INSStaggeredHierarchyIntegrator::regridProjection(initial_time);
  }
};
} // namespace eel2d
} // namespace ibamr_smarties
