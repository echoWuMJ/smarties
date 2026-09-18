#ifndef IBAMR_SMARTIES_EEL_ENVIRONMENT_H
#define IBAMR_SMARTIES_EEL_ENVIRONMENT_H

#include "EelControlMeasurement.h"
#include "EelVelocityProbes.h"
#include "EelNearWallTask.h"

#include <mpi.h>

#include <array>
#include <cstddef>
#include <memory>
#include <string>

namespace ibamr_smarties
{
namespace eel2d
{

class EelEnvironment
{
public:
  EelEnvironment();
  ~EelEnvironment();

  EelEnvironment(const EelEnvironment&) = delete;
  EelEnvironment& operator=(const EelEnvironment&) = delete;

  void initialize(MPI_Comm environment_comm, const std::string& input_file);
  // Caller keeps one IBTKInit alive across all independent physical episodes.
  void initializeNearWall(MPI_Comm environment_comm, const std::string& input_file,
                          const NearWallConfig& config, double initial_height,
                          const std::string& restart_directory = "");
  // Collective; caller owns a new, unpublished checkpoint directory.
  void writeRestart(const std::string& directory);
  NearWallObservation nearWallObservation() const;
  double currentForceX() const;
  void advanceOneStep();
  void setTailBeatFrequencyRatio(double ratio);
  ControlIntervalResult advanceControlInterval(double nominal_duration);
  double currentTime() const;
  std::array<double, 2> currentCenterOfMass() const;
  double currentBodyAxisAngle() const;
  EelVelocityProbeSample sampleVelocityProbes();
  double currentTailBeatPhase() const;
  double currentTailBeatFrequencyRatio() const;
  std::size_t globalLagrangianPointCount() const;
  bool stepsRemaining() const;
  void writeVisualizationSnapshot();
  void shutdown();

private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace eel2d
} // namespace ibamr_smarties

#endif
