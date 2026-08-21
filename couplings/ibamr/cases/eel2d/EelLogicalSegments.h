#ifndef IBAMR_SMARTIES_EEL_LOGICAL_SEGMENTS_H
#define IBAMR_SMARTIES_EEL_LOGICAL_SEGMENTS_H

namespace ibamr_smarties
{
namespace eel2d
{

enum class EelTransitionKind
{
  continuing,
  logical_horizon,
  ibamr_end_time
};

struct EelLogicalStep
{
  unsigned segment;
  unsigned segment_decision;
  unsigned total_decisions;
  EelTransitionKind kind;
};

class EelLogicalSegments
{
public:
  explicit EelLogicalSegments(unsigned episode_decisions);

  unsigned beginSegment();
  EelLogicalStep completeDecision(bool ibamr_steps_remaining);
  bool segmentActive() const;
  unsigned completedSegments() const;
  unsigned totalDecisions() const;

private:
  unsigned episode_decisions_;
  unsigned segments_started_;
  unsigned completed_segments_;
  unsigned segment_decisions_;
  unsigned total_decisions_;
  bool segment_active_;
};

} // namespace eel2d
} // namespace ibamr_smarties

#endif
