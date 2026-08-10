#include "CouplingDriver.h"
#include "EelSmartiesAdapter.h"

#include <cstdio>
#include <stdexcept>

int main(int argc, char** argv)
{
  ibamr_smarties::eel2d::EelMode mode;
  try {
    mode = ibamr_smarties::eel2d::parseEelMode(argc, argv);
  }
  catch (const std::invalid_argument& error) {
    std::fprintf(stderr, "eel2d mode error: %s\n", error.what());
    return 64;
  }

  ibamr_smarties::CouplingDriver driver(argc, argv);
  if (mode == ibamr_smarties::eel2d::EelMode::speed_tracking)
    return driver.run(ibamr_smarties::eel2d::runSpeedTrackingEpisode);
  return driver.run(ibamr_smarties::eel2d::runSmokeEpisode);
}
