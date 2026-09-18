#include "EelEnvironment.h"
#include "MpiSession.h"
#include <ibtk/IBTKInit.h>
#include <petscsys.h>
#include <tbox/SAMRAI_MPI.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <sys/stat.h>

// Two executions, fresh processes: write continues after saving; resume loads
// that save and performs the same steps. The Python caller compares results.
int main(int argc, char** argv) {
  ibamr_smarties::MpiSession mpi(argc,argv);
  int rank=0; MPI_Comm_rank(mpi.world(), &rank);
  try {
    if (argc!=4) throw std::invalid_argument("usage: probe write|resume input restart-directory");
    const bool resume=std::string(argv[1])=="resume";
    if (!resume && std::string(argv[1])!="write") throw std::invalid_argument("invalid mode");
    PETSC_COMM_WORLD=mpi.world();
    IBTK::IBTKInit runtime(argc,argv,mpi.world());
    SAMRAI::tbox::SAMRAI_MPI::setCommunicator(mpi.world());
    ibamr_smarties::eel2d::NearWallConfig config;
    ibamr_smarties::eel2d::EelEnvironment env;
    env.initializeNearWall(mpi.world(),argv[2],config,0.4,resume?argv[3]:"");
    if (!resume) {
      env.setTailBeatFrequencyRatio(1.2);
      env.advanceOneStep(); env.advanceOneStep();
      env.writeRestart(argv[3]);
    }
    const auto before=env.nearWallObservation();
    const double force_before=env.currentForceX();
    env.setTailBeatFrequencyRatio(0.9);
    const double continuation_start=env.currentTime();
    while (env.stepsRemaining() &&
           env.currentTime()-continuation_start<config.controlInterval())
      env.advanceOneStep();
    const auto after=env.nearWallObservation();
    const auto probes=env.sampleVelocityProbes();
    // Keep native end states for diagnosing a failed force comparison.
    const std::string final_dump = std::string(argv[3]) + (resume ? "-resumed" : "-continuous");
    if (!rank && mkdir(final_dump.c_str(),0700)) throw std::runtime_error("cannot create final probe dump");
    MPI_Barrier(mpi.world());
    env.writeRestart(final_dump);
    if (!rank) {
      std::ofstream out("restart-probe.txt");
      out << std::setprecision(17);
      for (const auto& o : {before,after})
        out << o.time << ' ' << o.height << ' ' << o.progress << ' '
            << o.velocity[0] << ' ' << o.velocity[1] << ' ' << o.body_angle << ' '
            << o.angular_velocity << ' ' << o.phase << ' ' << o.frequency_ratio << '\n';
      out << force_before << ' ' << env.currentForceX() << '\n';
      for (const auto& v: probes.velocities) out << v[0] << ' ' << v[1] << '\n';
      out.close(); if (!out) throw std::runtime_error("probe output failure");
    }
    env.shutdown();
    return 0;
  } catch (const std::exception& e) {
    if (!rank) std::cerr << e.what() << '\n';
    MPI_Abort(mpi.world(),98); return 98;
  }
}
