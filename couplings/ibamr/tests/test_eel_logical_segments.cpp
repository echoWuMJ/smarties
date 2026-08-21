#include "EelLogicalSegments.h"

#include <stdexcept>

int main()
{
  using namespace ibamr_smarties::eel2d;

  bool rejected_zero = false;
  try { EelLogicalSegments invalid(0); }
  catch (const std::invalid_argument&) { rejected_zero = true; }
  if (!rejected_zero) return 1;

  EelLogicalSegments segments(2);
  if (segments.beginSegment() != 1) return 2;
  const auto first = segments.completeDecision(true);
  if (first.segment != 1 || first.segment_decision != 1 ||
      first.total_decisions != 1 ||
      first.kind != EelTransitionKind::continuing) return 3;
  const auto first_boundary = segments.completeDecision(true);
  if (first_boundary.segment_decision != 2 ||
      first_boundary.kind != EelTransitionKind::logical_horizon ||
      segments.segmentActive() || segments.completedSegments() != 1) return 4;

  if (segments.beginSegment() != 2) return 5;
  const auto second = segments.completeDecision(false);
  if (second.segment != 2 || second.segment_decision != 1 ||
      second.total_decisions != 3 ||
      second.kind != EelTransitionKind::ibamr_end_time ||
      segments.completedSegments() != 2) return 6;
  return 0;
}
