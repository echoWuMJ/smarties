#include "EelLogicalSegments.h"

#include <stdexcept>

namespace ibamr_smarties
{
namespace eel2d
{

EelLogicalSegments::EelLogicalSegments(unsigned episode_decisions)
  : episode_decisions_(episode_decisions),
    segments_started_(0),
    completed_segments_(0),
    segment_decisions_(0),
    total_decisions_(0),
    segment_active_(false)
{
  if (episode_decisions_ == 0) throw std::invalid_argument("episode horizon must be positive");
}

unsigned EelLogicalSegments::beginSegment()
{
  if (segment_active_) throw std::logic_error("segment is already active");
  ++segments_started_;
  segment_decisions_ = 0;
  segment_active_ = true;
  return segments_started_;
}

EelLogicalStep EelLogicalSegments::completeDecision(bool ibamr_steps_remaining)
{
  if (!segment_active_) throw std::logic_error("no active segment");
  ++segment_decisions_;
  ++total_decisions_;

  EelTransitionKind kind;
  if (!ibamr_steps_remaining)
    kind = EelTransitionKind::ibamr_end_time;
  else if (segment_decisions_ == episode_decisions_)
    kind = EelTransitionKind::logical_horizon;
  else
    kind = EelTransitionKind::continuing;

  if (kind != EelTransitionKind::continuing)
  {
    segment_active_ = false;
    ++completed_segments_;
  }

  return {segments_started_, segment_decisions_, total_decisions_, kind};
}

bool EelLogicalSegments::segmentActive() const
{
  return segment_active_;
}

unsigned EelLogicalSegments::completedSegments() const
{
  return completed_segments_;
}

unsigned EelLogicalSegments::totalDecisions() const
{
  return total_decisions_;
}

} // namespace eel2d
} // namespace ibamr_smarties
