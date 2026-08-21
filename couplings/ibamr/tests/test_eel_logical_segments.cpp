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
  const auto second_continuing = segments.completeDecision(true);
  if (second_continuing.segment != 2 ||
      second_continuing.segment_decision != 1 ||
      second_continuing.total_decisions != 3 ||
      second_continuing.kind != EelTransitionKind::continuing) return 6;
  const auto second = segments.completeDecision(false);
  if (second.segment != 2 || second.segment_decision != 2 ||
      second.total_decisions != 4 ||
      second.kind != EelTransitionKind::ibamr_end_time ||
      segments.segmentActive() || segments.completedSegments() != 2) return 7;

  bool rejected_inactive_completion = false;
  try { segments.completeDecision(true); }
  catch (const std::logic_error&) { rejected_inactive_completion = true; }
  if (!rejected_inactive_completion) return 8;

  EelLogicalSegments active(2);
  active.beginSegment();
  bool rejected_duplicate_begin = false;
  try { active.beginSegment(); }
  catch (const std::logic_error&) { rejected_duplicate_begin = true; }
  if (!rejected_duplicate_begin) return 9;
  return 0;
}
