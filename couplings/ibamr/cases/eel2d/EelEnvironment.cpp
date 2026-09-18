// Derived from IBAMR 0.18.0 examples/ConstraintIB/eel2d/example.cpp.
// IBAMR is distributed under the 3-clause BSD license.

#include "EelEnvironment.h"
#include "RegridSafeINSStaggeredHierarchyIntegrator.h"

#include <SAMRAI_config.h>
#include <petscsys.h>

#include <tbox/SAMRAI_MPI.h>

#include <BergerRigoutsos.h>
#include <CartesianGridGeometry.h>
#include <LoadBalancer.h>
#include <HierarchyDataOpsManager.h>
#include <HierarchyDataOpsReal.h>
#include <SideVariable.h>
#include <StandardTagAndInitialize.h>

#include <ibamr/ConstraintIBMethod.h>
#include <ibamr/IBExplicitHierarchyIntegrator.h>
#include <ibamr/IBHydrodynamicForceEvaluator.h>
#include <ibamr/IBStandardForceGen.h>
#include <ibamr/IBStandardInitializer.h>
#include <ibamr/INSCollocatedHierarchyIntegrator.h>
#include <ibamr/INSStaggeredHierarchyIntegrator.h>
#include <ibamr/INSStaggeredPressureBcCoef.h>

#include <ibtk/AppInitializer.h>
#include <ibtk/CartCellDoubleCubicCoarsen.h>
#include <ibtk/CartSideDoubleCubicCoarsen.h>
#include <ibtk/IBTKInit.h>
#include <ibtk/IBTK_MPI.h>
#include <ibtk/HierarchyGhostCellInterpolation.h>
#include <ibtk/LData.h>
#include <ibtk/interpolation_utilities.h>
#include <ibtk/muParserCartGridFunction.h>
#include <ibtk/muParserRobinBcCoefs.h>

#include <ibamr/app_namespaces.h>

#include "IBEELKinematics.h"

#include <array>
#include <fstream>
#include <iomanip>
#include <limits>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <vector>

namespace ibamr_smarties
{
namespace eel2d
{
namespace
{

constexpr int EEL_PROBE_DATA_DEPTH = 1;
constexpr int EEL_PROBE_GHOST_WIDTH = 3;

void output_data(Pointer<PatchHierarchy<NDIM> > patch_hierarchy,
                 Pointer<INSHierarchyIntegrator> navier_stokes_integrator,
                 LDataManager* l_data_manager,
                 int iteration_num,
                 double loop_time,
                 const string& data_dump_dirname);

} // namespace

class EelEnvironment::Impl
{
public:
  void initialize(MPI_Comm environment_comm, const std::string& input_file,
                  const NearWallConfig* config = nullptr, double initial_height = 0,
                  const std::string& restart_directory = "");
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
  void writeVisualizationSnapshot();
  bool stepsRemaining() const;
  void shutdown();

  ~Impl() { shutdown(); }

private:
  void writeVisualizationData();

  bool ready_ = false;
  bool shutdown_started_ = false;
  MPI_Comm environment_comm_ = MPI_COMM_NULL;

  int argc_ = 2;
  std::vector<char> executable_arg_;
  std::vector<char> input_arg_;
  std::vector<char> restart_arg_, restart_step_arg_;
  std::array<char*, 5> argv_{{nullptr, nullptr, nullptr, nullptr, nullptr}};
  std::unique_ptr<IBTKInit> ibtk_init_;

  Pointer<AppInitializer> app_initializer_;
  Pointer<Database> input_db_;
  Pointer<INSHierarchyIntegrator> navier_stokes_integrator_;
  Pointer<ConstraintIBMethod> ib_method_ops_;
  Pointer<IBHierarchyIntegrator> time_integrator_;
  Pointer<CartesianGridGeometry<NDIM> > grid_geometry_;
  Pointer<PatchHierarchy<NDIM> > patch_hierarchy_;
  Pointer<StandardTagAndInitialize<NDIM> > error_detector_;
  Pointer<BergerRigoutsos<NDIM> > box_generator_;
  Pointer<LoadBalancer<NDIM> > load_balancer_;
  Pointer<GriddingAlgorithm<NDIM> > gridding_algorithm_;
  Pointer<IBStandardInitializer> ib_initializer_;
  Pointer<IBStandardForceGen> ib_force_fcn_;
  Pointer<CartGridFunction> u_init_;
  Pointer<CartGridFunction> p_init_;
  Pointer<CartGridFunction> f_fcn_;
  Pointer<Variable<NDIM> > u_var_;
  Pointer<SideVariable<NDIM, double> > probe_u_var_;
  std::vector<RobinBcCoefStrategy<NDIM>*> u_bc_coefs_;
  Pointer<VisItDataWriter<NDIM> > visit_data_writer_;
  Pointer<LSiloDataWriter> silo_data_writer_;
  std::vector<Pointer<ConstraintIBKinematics> > ibkinematics_ops_vec_;
  Pointer<IBEELKinematics> ib_kinematics_op_;
  Pointer<IBHydrodynamicForceEvaluator> hydro_force_;

  bool dump_viz_data_ = false;
  int viz_dump_interval_ = 0;
  bool uses_visit_ = false;
  bool dump_restart_data_ = false;
  int restart_dump_interval_ = 0;
  string restart_dump_dirname_;
  bool dump_postproc_data_ = false;
  int postproc_data_dump_interval_ = 0;
  string postproc_data_dump_dirname_;
  bool dump_timer_data_ = false;
  int timer_dump_interval_ = 0;

  int u_idx_ = -1;
  int probe_u_idx_ = -1;
  int p_idx_ = -1;
  int iteration_num_ = 0;
  int last_visualization_iteration_ = -1;
  double loop_time_ = 0.0;
  double loop_time_end_ = 0.0;
  double box_disp_ = 0.0;
  std::vector<std::vector<double> > structure_COM_;
  IBTK::Vector3d eel_COM_;
  bool borrowed_runtime_ = false;
  bool near_wall_ = false;
  NearWallConfig near_wall_config_;
  double initial_com_x_ = 0;
  double last_angle_ = 0;
  double angular_velocity_ = 0;
};

void
EelEnvironment::Impl::initialize(MPI_Comm environment_comm, const std::string& input_file,
                                const NearWallConfig* config, double initial_height,
                                const std::string& restart_directory)
{
  if (ready_ || ibtk_init_) throw std::logic_error("EelEnvironment is already initialized");
  if (environment_comm == MPI_COMM_NULL)
    throw std::invalid_argument("EelEnvironment requires a valid communicator");
  if (input_file.empty()) throw std::invalid_argument("EelEnvironment requires an input file");

  environment_comm_ = environment_comm;
  PETSC_COMM_WORLD = environment_comm_;

  const std::string executable_name = "ibamr_eel2d_environment";
  executable_arg_.assign(executable_name.begin(), executable_name.end());
  executable_arg_.push_back('\0');
  input_arg_.assign(input_file.begin(), input_file.end());
  input_arg_.push_back('\0');
  argv_[0] = executable_arg_.data();
  argv_[1] = input_arg_.data();
  argv_[2] = nullptr;

  const bool restarting = !restart_directory.empty();
  double saved_time = 0, saved_origin = 0, saved_angle = 0, saved_angular_velocity = 0, saved_box_disp = 0;
  int saved_step = 0;
  if (restarting) {
    if (!config) throw std::invalid_argument("paired CFD restart requires near-wall configuration");
    std::ifstream state(restart_directory + "/environment.state");
    int version = 0;
    if (!(state >> version >> saved_step >> saved_time >> saved_origin >> saved_angle
                >> saved_angular_velocity >> saved_box_disp) || version != 1 || saved_step < 0)
      throw std::runtime_error("invalid CFD checkpoint sidecar");
    std::string extra;
    if (state >> extra) throw std::runtime_error("extra CFD checkpoint sidecar fields");
    for (double value : {saved_time, saved_origin, saved_angle, saved_angular_velocity, saved_box_disp})
      if (!std::isfinite(value)) throw std::runtime_error("non-finite CFD checkpoint state");
    if (saved_time < 0) throw std::runtime_error("negative CFD checkpoint time");
    const std::string native_directory = restart_directory + "/samrai";
    const std::string step_string = std::to_string(saved_step);
    restart_arg_.assign(native_directory.begin(), native_directory.end()); restart_arg_.push_back('\0');
    restart_step_arg_.assign(step_string.begin(), step_string.end()); restart_step_arg_.push_back('\0');
    argc_ = 4;
    argv_[2] = restart_arg_.data(); argv_[3] = restart_step_arg_.data(); argv_[4] = nullptr;
  }

  borrowed_runtime_ = config != nullptr;
  near_wall_ = config != nullptr;
  if (config) { config->validate(); near_wall_config_ = *config; }
  if (!borrowed_runtime_)
    ibtk_init_.reset(new IBTKInit(argc_, argv_.data(), environment_comm_));
  // IBAMR 0.18's bundled SAMRAI startup resets its communicator to
  // SAMRAI_MPI::commWorld after IBTKInit first assigns the supplied subcomm.
  // Restore the environment communicator before AppInitializer broadcasts.
  SAMRAI::tbox::SAMRAI_MPI::setCommunicator(environment_comm_);
  shutdown_started_ = false;
  last_visualization_iteration_ = -1;

  try
  {
    app_initializer_ = new AppInitializer(argc_, argv_.data(), "IB.log");
    input_db_ = app_initializer_->getInputDatabase();
    if (near_wall_)
    {
      // Translate the original vertex set, never resample its geometry.
      std::ifstream vertices("eel2d.vertex");
      std::size_t count = 0;
      if (!(vertices >> count) || count == 0)
        throw std::runtime_error("cannot read original eel2d.vertex");
      double sum_y = 0, x, y;
      for (std::size_t i = 0; i < count; ++i) {
        if (!(vertices >> x >> y)) throw std::runtime_error("invalid eel2d.vertex");
        sum_y += y;
      }
      const double shift[NDIM] = {0.0, config->wall_y + initial_height - sum_y/count};
      input_db_->getDatabase("IBStandardInitializer")->putDoubleArray("posn_shift", shift, NDIM);
      int periodic[NDIM] = {1, 0};
      auto geometry = input_db_->getDatabase("CartesianGeometry");
      geometry->putIntegerArray("periodic_dimension", periodic, NDIM);
      double lower[NDIM];
      geometry->getDoubleArray("x_lo", lower, NDIM);
      if (std::abs(lower[1] - config->wall_y) > 1e-12)
        throw std::runtime_error("near-wall wall_y must equal lower domain boundary");
      // The CV must contain the fish without crossing the physical wall.
      // Its lower face coincides with the physical wall; the control-volume
      // surface integral must include the wall traction.
      const double cv_lower[3] = {-1.0, config->wall_y, 0.0};
      const double cv_upper[3] = {1.0, config->wall_y + 1.0, 0.0};
      auto cv = input_db_->getDatabase("InitHydroForceBox_0");
      cv->putDoubleArray("lower_left_corner", cv_lower, 3);
      cv->putDoubleArray("upper_right_corner", cv_upper, 3);
    }

    dump_viz_data_ = app_initializer_->dumpVizData();
    viz_dump_interval_ = app_initializer_->getVizDumpInterval();
    uses_visit_ = dump_viz_data_ && !app_initializer_->getVisItDataWriter().isNull();

    dump_restart_data_ = app_initializer_->dumpRestartData();
    restart_dump_interval_ = app_initializer_->getRestartDumpInterval();
    restart_dump_dirname_ = app_initializer_->getRestartDumpDirectory();

    dump_postproc_data_ = app_initializer_->dumpPostProcessingData();
    postproc_data_dump_interval_ = app_initializer_->getPostProcessingDataDumpInterval();
    postproc_data_dump_dirname_ = app_initializer_->getPostProcessingDataDumpDirectory();
    if (dump_postproc_data_ && postproc_data_dump_interval_ > 0 &&
        !postproc_data_dump_dirname_.empty())
      Utilities::recursiveMkdir(postproc_data_dump_dirname_);

    dump_timer_data_ = app_initializer_->dumpTimerData();
    timer_dump_interval_ = app_initializer_->getTimerDumpInterval();

    navier_stokes_integrator_ = new RegridSafeINSStaggeredHierarchyIntegrator(
      "INSStaggeredHierarchyIntegrator",
      app_initializer_->getComponentDatabase("INSStaggeredHierarchyIntegrator"));

    const int num_structures = input_db_->getIntegerWithDefault("num_structures", 1);
    ib_method_ops_ = new ConstraintIBMethod(
      "ConstraintIBMethod",
      app_initializer_->getComponentDatabase("ConstraintIBMethod"),
      num_structures);
    time_integrator_ = new IBExplicitHierarchyIntegrator(
      "IBHierarchyIntegrator",
      app_initializer_->getComponentDatabase("IBHierarchyIntegrator"),
      ib_method_ops_,
      navier_stokes_integrator_);

    grid_geometry_ = new CartesianGridGeometry<NDIM>(
      "CartesianGeometry", app_initializer_->getComponentDatabase("CartesianGeometry"));
    if (near_wall_) {
      // IBTK's IBTK_DO_ONCE registration belongs to the first geometry only.
      // Every independent episode constructs a new geometry needing operators.
      grid_geometry_->addSpatialCoarsenOperator(new IBTK::CartCellDoubleCubicCoarsen());
      grid_geometry_->addSpatialCoarsenOperator(new IBTK::CartSideDoubleCubicCoarsen());
    }
    patch_hierarchy_ = new PatchHierarchy<NDIM>("PatchHierarchy", grid_geometry_);

    error_detector_ = new StandardTagAndInitialize<NDIM>(
      "StandardTagAndInitialize",
      time_integrator_,
      app_initializer_->getComponentDatabase("StandardTagAndInitialize"));
    box_generator_ = new BergerRigoutsos<NDIM>();
    load_balancer_ = new LoadBalancer<NDIM>(
      "LoadBalancer", app_initializer_->getComponentDatabase("LoadBalancer"));
    gridding_algorithm_ = new GriddingAlgorithm<NDIM>(
      "GriddingAlgorithm",
      app_initializer_->getComponentDatabase("GriddingAlgorithm"),
      error_detector_,
      box_generator_,
      load_balancer_);

    ib_initializer_ = new IBStandardInitializer(
      "IBStandardInitializer", app_initializer_->getComponentDatabase("IBStandardInitializer"));
    ib_method_ops_->registerLInitStrategy(ib_initializer_);
    ib_force_fcn_ = new IBStandardForceGen();
    ib_method_ops_->registerIBLagrangianForceFunction(ib_force_fcn_);

    if (input_db_->keyExists("VelocityInitialConditions"))
    {
      u_init_ = new muParserCartGridFunction(
        "u_init", app_initializer_->getComponentDatabase("VelocityInitialConditions"), grid_geometry_);
      navier_stokes_integrator_->registerVelocityInitialConditions(u_init_);
    }

    if (input_db_->keyExists("PressureInitialConditions"))
    {
      p_init_ = new muParserCartGridFunction(
        "p_init", app_initializer_->getComponentDatabase("PressureInitialConditions"), grid_geometry_);
      navier_stokes_integrator_->registerPressureInitialConditions(p_init_);
    }

    const IntVector<NDIM>& periodic_shift = grid_geometry_->getPeriodicShift();
    u_bc_coefs_.resize(NDIM, nullptr);
    if (periodic_shift.min() <= 0)
    {
      for (unsigned int d = 0; d < NDIM; ++d)
      {
        const std::string bc_coefs_name = "u_bc_coefs_" + std::to_string(d);
        const std::string bc_coefs_db_name = "VelocityBcCoefs_" + std::to_string(d);
        u_bc_coefs_[d] = new muParserRobinBcCoefs(
          bc_coefs_name,
          app_initializer_->getComponentDatabase(bc_coefs_db_name),
          grid_geometry_);
      }
      navier_stokes_integrator_->registerPhysicalBoundaryConditions(u_bc_coefs_);
    }

    if (input_db_->keyExists("ForcingFunction"))
    {
      f_fcn_ = new muParserCartGridFunction(
        "f_fcn", app_initializer_->getComponentDatabase("ForcingFunction"), grid_geometry_);
      time_integrator_->registerBodyForceFunction(f_fcn_);
    }

    visit_data_writer_ = app_initializer_->getVisItDataWriter();
    silo_data_writer_ = app_initializer_->getLSiloDataWriter();
    if (uses_visit_)
    {
      ib_initializer_->registerLSiloDataWriter(silo_data_writer_);
      ib_method_ops_->registerLSiloDataWriter(silo_data_writer_);
      time_integrator_->registerVisItDataWriter(visit_data_writer_);
    }

    time_integrator_->initializePatchHierarchy(patch_hierarchy_, gridding_algorithm_);

    ib_kinematics_op_ = new IBEELKinematics(
      "eel2d",
      app_initializer_->getComponentDatabase("ConstraintIBKinematics")->getDatabase("eel2d"),
      ib_method_ops_->getLDataManager(),
      patch_hierarchy_);
    ibkinematics_ops_vec_.push_back(ib_kinematics_op_);
    ib_method_ops_->registerConstraintIBKinematics(ibkinematics_ops_vec_);
    ib_method_ops_->initializeHierarchyOperatorsandData();

    const double rho_fluid = input_db_->getDouble("RHO");
    const double mu_fluid = input_db_->getDouble("MU");
    const double start_time = time_integrator_->getIntegratorTime();
    hydro_force_ = new IBHydrodynamicForceEvaluator(
      "IBHydrodynamicForce", rho_fluid, mu_fluid, start_time, true);

    const string init_hydro_force_box_db_name = "InitHydroForceBox_0";
    IBTK::Vector3d box_X_lower, box_X_upper, box_init_vel;
    input_db_->getDatabase(init_hydro_force_box_db_name)
      ->getDoubleArray("lower_left_corner", &box_X_lower[0], 3);
    input_db_->getDatabase(init_hydro_force_box_db_name)
      ->getDoubleArray("upper_right_corner", &box_X_upper[0], 3);
    input_db_->getDatabase(init_hydro_force_box_db_name)
      ->getDoubleArray("init_velocity", &box_init_vel[0], 3);
    hydro_force_->registerStructure(box_X_lower, box_X_upper, patch_hierarchy_, box_init_vel, 0);

    if (restarting) {
      // IBAMR 0.18's calculateStructure{,Rotational}Momentum accumulates into
      // these vectors, but ConstraintIBMethod's restart does not save them.
      // The force evaluator DOES save the identical values as P/L_current.
      // Preserve the continuous-run history, without changing its numerics.
      // The views refer to mutable members of our non-const, owned object;
      // 0.18 exposes getters but no setter for restoring this missing history.
      using Momentum = std::vector<std::vector<double>>;
      auto& momentum = const_cast<Momentum&>(ib_method_ops_->getStructureMomentum());
      auto& angular_momentum = const_cast<Momentum&>(ib_method_ops_->getStructureRotationalMomentum());
      if (momentum.size() != 1 || angular_momentum.size() != 1 ||
          momentum[0].size() != 3 || angular_momentum[0].size() != 3)
        throw std::runtime_error("unsupported ConstraintIB restart momentum layout");
      const auto& saved_force = hydro_force_->getHydrodynamicForceObject(0);
      for (int d = 0; d < 3; ++d) {
        momentum[0][d] = saved_force.P_current[d];
        angular_momentum[0][d] = saved_force.L_current[d];
      }
    }

    structure_COM_ = ib_method_ops_->getCurrentStructureCOM();
    for (int d = 0; d < 3; ++d) eel_COM_[d] = structure_COM_[0][d];
    hydro_force_->setTorqueOrigin(eel_COM_, 0);
    hydro_force_->registerStructurePlotData(visit_data_writer_, patch_hierarchy_, 0);

    ib_method_ops_->freeLInitStrategy();
    ib_initializer_.setNull();
    app_initializer_.setNull();

    plog << "Input database:\n";
    input_db_->printClassData(plog);

    VariableDatabase<NDIM>* var_db = VariableDatabase<NDIM>::getDatabase();
    u_var_ = navier_stokes_integrator_->getVelocityVariable();
    const Pointer<VariableContext> u_ctx = navier_stokes_integrator_->getCurrentContext();
    u_idx_ = var_db->mapVariableAndContextToIndex(u_var_, u_ctx);
    probe_u_var_ =
      new SideVariable<NDIM, double>("EelEnvironment::probe_velocity", 1);
    const Pointer<VariableContext> probe_u_ctx =
      var_db->getContext("EelEnvironment::probe_velocity_context");
    probe_u_idx_ =
      var_db->registerVariableAndContext(
        probe_u_var_, probe_u_ctx, EEL_PROBE_GHOST_WIDTH);
    const Pointer<Variable<NDIM> > p_var = navier_stokes_integrator_->getPressureVariable();
    const Pointer<VariableContext> p_ctx = navier_stokes_integrator_->getCurrentContext();
    p_idx_ = var_db->mapVariableAndContextToIndex(p_var, p_ctx);

    iteration_num_ = time_integrator_->getIntegratorStep();
    loop_time_ = time_integrator_->getIntegratorTime();
    if (dump_viz_data_ && uses_visit_)
    {
      pout << "\n\nWriting visualization files...\n\n";
      writeVisualizationData();
    }

    loop_time_end_ = time_integrator_->getEndTime();
    ready_ = true;
    initial_com_x_ = eel_COM_[0];
    last_angle_ = currentBodyAxisAngle();
    if (restarting) {
      if (iteration_num_ != saved_step || loop_time_ != saved_time)
        throw std::runtime_error("CFD native restart and case sidecar do not match");
      initial_com_x_ = saved_origin;
      last_angle_ = saved_angle;
      angular_velocity_ = saved_angular_velocity;
      box_disp_ = saved_box_disp;
    }
    if (near_wall_ && !restarting && std::abs(eel_COM_[1] - config->wall_y - initial_height) > 1e-5)
      throw std::runtime_error("near-wall initial COM shift was not applied");
  }
  catch (...)
  {
    shutdown();
    throw;
  }
}

void EelEnvironment::Impl::writeRestart(const std::string& directory)
{
  if (!ready_ || !near_wall_ || directory.empty())
    throw std::logic_error("CFD restart requires a ready near-wall environment and destination");
  // Library objects own the hierarchy, structure, flow and force history.
  // These scalar case fields are not registered library restart objects.
  RestartManager::getManager()->writeRestartFile(directory + "/samrai", iteration_num_);
  int rank = 0;
  MPI_Comm_rank(environment_comm_, &rank);
  int written = 1;
  if (rank == 0) {
    std::ofstream state(directory + "/environment.state");
    state << std::setprecision(17) << 1 << ' ' << iteration_num_ << ' ' << loop_time_ << ' '
          << initial_com_x_ << ' ' << last_angle_ << ' ' << angular_velocity_ << ' ' << box_disp_ << '\n';
    state.close();
    written = bool(state);
  }
  MPI_Bcast(&written, 1, MPI_INT, 0, environment_comm_);
  if (!written) throw std::runtime_error("cannot write CFD checkpoint sidecar");
}

bool
EelEnvironment::Impl::stepsRemaining() const
{
  return ready_ && !IBTK::rel_equal_eps(loop_time_, loop_time_end_) &&
         time_integrator_->stepsRemaining();
}

double
EelEnvironment::Impl::currentTime() const
{
  if (!ready_) throw std::logic_error("EelEnvironment is not initialized");
  return loop_time_;
}

std::array<double, 2>
EelEnvironment::Impl::currentCenterOfMass() const
{
  if (!ready_) throw std::logic_error("EelEnvironment is not initialized");
  return {{ eel_COM_[0], eel_COM_[1] }};
}

double
EelEnvironment::Impl::currentTailBeatPhase() const
{
  if (!ready_ || ib_kinematics_op_.isNull())
    throw std::logic_error("EelEnvironment kinematics are not initialized");
  return ib_kinematics_op_->getTailBeatPhase(loop_time_);
}

double
EelEnvironment::Impl::currentTailBeatFrequencyRatio() const
{
  if (!ready_ || ib_kinematics_op_.isNull())
    throw std::logic_error("EelEnvironment kinematics are not initialized");
  return ib_kinematics_op_->getTailBeatFrequencyRatio();
}

std::size_t
EelEnvironment::Impl::globalLagrangianPointCount() const
{
  if (!ready_ || ib_kinematics_op_.isNull())
    throw std::logic_error("EelEnvironment kinematics are not initialized");
  return ib_kinematics_op_->getGlobalLagrangianPointCount();
}

double EelEnvironment::Impl::currentForceX() const
{
  if (!ready_) throw std::logic_error("EelEnvironment is not initialized");
  return hydro_force_->getHydrodynamicForceObject(0).F_current[0];
}

NearWallObservation EelEnvironment::Impl::nearWallObservation() const
{
  if (!ready_ || !near_wall_) throw std::logic_error("near-wall environment is not initialized");
  NearWallObservation o;
  o.time = loop_time_;
  o.height = eel_COM_[1] - near_wall_config_.wall_y;
  o.progress = initial_com_x_ - eel_COM_[0];
  const auto& velocity = ib_method_ops_->getCurrentCOMVelocity();
  o.velocity = {{velocity[0][0], velocity[0][1]}};
  o.body_angle = currentBodyAxisAngle();
  o.angular_velocity = angular_velocity_;
  o.phase = currentTailBeatPhase();
  o.frequency_ratio = currentTailBeatFrequencyRatio();
  double local_min[NDIM] = {std::numeric_limits<double>::max(), std::numeric_limits<double>::max()};
  double local_max[NDIM] = {-std::numeric_limits<double>::max(), -std::numeric_limits<double>::max()};
  auto* manager = ib_method_ops_->getLDataManager();
  for (int ln=0; ln<=patch_hierarchy_->getFinestLevelNumber(); ++ln) {
    if (!manager->levelContainsLagrangianData(ln)) continue;
    Pointer<LData> data = manager->getLData("X", ln);
    auto* X = data->getLocalFormVecArray();
    for (unsigned i=0; i<data->getLocalNodeCount(); ++i)
      for (int d=0; d<NDIM; ++d) {
        local_min[d] = std::min(local_min[d], (*X)[i][d]);
        local_max[d] = std::max(local_max[d], (*X)[i][d]);
      }
    data->restoreArrays();
  }
  double minimum[NDIM], maximum[NDIM];
  MPI_Allreduce(local_min, minimum, NDIM, MPI_DOUBLE, MPI_MIN, environment_comm_);
  MPI_Allreduce(local_max, maximum, NDIM, MPI_DOUBLE, MPI_MAX, environment_comm_);
  o.minimum_gap = minimum[1] - near_wall_config_.wall_y;
  const double* lo = grid_geometry_->getXLower();
  const double* hi = grid_geometry_->getXUpper();
  o.outside_safe_domain = minimum[0] <= lo[0]+1.0 || maximum[0] >= hi[0]-0.25 ||
                         maximum[1] >= hi[1]-0.25;
  return o;
}

double
EelEnvironment::Impl::currentBodyAxisAngle() const
{
  if (!ready_ || ib_kinematics_op_.isNull())
    throw std::logic_error("EelEnvironment kinematics are not initialized");
  return ib_kinematics_op_->getBodyAxisAngle();
}

EelVelocityProbeSample
EelEnvironment::Impl::sampleVelocityProbes()
{
  if (!ready_ || patch_hierarchy_.isNull() || probe_u_var_.isNull() ||
      u_idx_ < 0 || probe_u_idx_ < 0)
    throw std::logic_error("EelEnvironment velocity field is not initialized");

  EelVelocityProbeSample sample;
  sample.positions =
    makeEelProbePoints(currentCenterOfMass(), currentBodyAxisAngle());
  if (near_wall_)
  {
    const double* lower = grid_geometry_->getXLower();
    const double* upper = grid_geometry_->getXUpper();
    for (const auto& p : sample.positions)
      if (p[0] <= lower[0] || p[0] >= upper[0] || p[1] <= lower[1] || p[1] >= upper[1])
        throw std::runtime_error("near-wall velocity probe is outside the physical fluid domain");
  }

  using ITC =
    IBTK::HierarchyGhostCellInterpolation::InterpolationTransactionComponent;
  for (int level_number = 0;
       level_number <= patch_hierarchy_->getFinestLevelNumber();
       ++level_number)
  {
    Pointer<PatchLevel<NDIM> > level =
      patch_hierarchy_->getPatchLevel(level_number);
    if (!level->checkAllocated(probe_u_idx_))
      level->allocatePatchData(probe_u_idx_, loop_time_);
  }
  HierarchyDataOpsManager<NDIM>* data_ops_manager =
    HierarchyDataOpsManager<NDIM>::getManager();
  Pointer<HierarchyDataOpsReal<NDIM, double> > probe_data_ops =
    data_ops_manager->getOperationsDouble(probe_u_var_, patch_hierarchy_, true);
  probe_data_ops->copyData(probe_u_idx_, u_idx_, true);

  const std::vector<ITC> transactions = {{ ITC(
    probe_u_idx_, u_idx_, "CONSERVATIVE_LINEAR_REFINE", true, "CUBIC_COARSEN",
    "LINEAR", false, u_bc_coefs_) }};
  Pointer<IBTK::HierarchyGhostCellInterpolation> ghost_fill =
    new IBTK::HierarchyGhostCellInterpolation();
  ghost_fill->initializeOperatorState(transactions, patch_hierarchy_);
  ghost_fill->setHomogeneousBc(false);
  ghost_fill->fillData(loop_time_);
  ghost_fill->deallocateOperatorState();

  std::vector<IBTK::VectorNd> locations(EEL_PROBE_COUNT);
  for (std::size_t probe = 0; probe < EEL_PROBE_COUNT; ++probe)
  {
    locations[probe][0] = sample.positions[probe][0];
    locations[probe][1] = sample.positions[probe][1];
  }
  std::vector<double> values;
  values.reserve(EEL_PROBE_COUNT * EEL_PROBE_COMPONENT_COUNT);
  for (const IBTK::VectorNd& location : locations)
  {
    const std::vector<double> probe_values =
      IBTK::interpolate(location, probe_u_idx_, probe_u_var_,
                        EEL_PROBE_DATA_DEPTH,
                        patch_hierarchy_, "IB_4");
    values.insert(values.end(), probe_values.begin(), probe_values.end());
  }
  if (values.size() != EEL_PROBE_COUNT * EEL_PROBE_COMPONENT_COUNT)
    throw std::runtime_error("IBAMR returned an invalid eel probe velocity count");

  for (std::size_t probe = 0; probe < EEL_PROBE_COUNT; ++probe)
  {
    for (std::size_t component = 0;
         component < EEL_PROBE_COMPONENT_COUNT;
         ++component)
    {
      const double value =
        values[EEL_PROBE_COMPONENT_COUNT * probe + component];
      if (!std::isfinite(value))
        throw std::runtime_error("IBAMR returned a non-finite eel probe velocity");
      sample.velocities[probe][component] = value;
    }
  }
  return sample;
}

void
EelEnvironment::Impl::writeVisualizationSnapshot()
{
  if (!ready_) throw std::logic_error("EelEnvironment is not initialized");
  writeVisualizationData();
}

void
EelEnvironment::Impl::writeVisualizationData()
{
  if (!dump_viz_data_ || !uses_visit_ ||
      last_visualization_iteration_ == iteration_num_)
    return;
  time_integrator_->setupPlotData();
  visit_data_writer_->writePlotData(patch_hierarchy_, iteration_num_, loop_time_);
  silo_data_writer_->writePlotData(iteration_num_, loop_time_);
  last_visualization_iteration_ = iteration_num_;
}

void
EelEnvironment::Impl::setTailBeatFrequencyRatio(const double ratio)
{
  if (!ready_ || ib_kinematics_op_.isNull())
    throw std::logic_error("EelEnvironment kinematics are not initialized");
  ib_kinematics_op_->setTailBeatFrequencyRatio(ratio, loop_time_);
}

ControlIntervalResult
EelEnvironment::Impl::advanceControlInterval(const double nominal_duration)
{
  if (!std::isfinite(nominal_duration) || nominal_duration <= 0.0)
    throw std::invalid_argument("control interval duration must be finite and positive");
  if (!stepsRemaining()) throw std::logic_error("EelEnvironment has no control interval remaining");

  ControlIntervalResult result;
  result.start_time = loop_time_;
  result.start_com = currentCenterOfMass();
  result.ibamr_steps = 0;
  const double target_time = result.start_time + nominal_duration;
  while (stepsRemaining() && loop_time_ < target_time)
  {
    advanceOneStep();
    ++result.ibamr_steps;
  }
  result.end_time = loop_time_;
  result.end_com = currentCenterOfMass();
  return result;
}

void
EelEnvironment::Impl::advanceOneStep()
{
  if (!stepsRemaining()) throw std::logic_error("EelEnvironment has no step remaining");

  iteration_num_ = time_integrator_->getIntegratorStep();
  loop_time_ = time_integrator_->getIntegratorTime();
  const double current_time = loop_time_;

  pout << "\n";
  pout << "+++++++++++++++++++++++++++++++++++++++++++++++++++\n";
  pout << "At beginning of timestep # " << iteration_num_ << "\n";
  pout << "Simulation time is " << loop_time_ << "\n";

  const double dt = time_integrator_->getMaximumTimeStepSize();
  loop_time_ += dt;
  const double new_time = loop_time_;

  if (time_integrator_->atRegridPoint()) time_integrator_->regridHierarchy();

  IBTK::Vector3d box_vel;
  box_vel.setZero();
  std::vector<std::vector<double> > COM_vel = ib_method_ops_->getCurrentCOMVelocity();
  for (int d = 0; d < NDIM; ++d) box_vel(d) = COM_vel[0][d];

  const int coarsest_ln = 0;
  Pointer<PatchLevel<NDIM> > coarsest_level = patch_hierarchy_->getPatchLevel(coarsest_ln);
  const Pointer<CartesianGridGeometry<NDIM> > coarsest_grid_geom = coarsest_level->getGridGeometry();
  const double* const DX = coarsest_grid_geom->getDx();

  box_disp_ += box_vel[0] * dt;
  if (std::abs(box_disp_) >= std::abs(0.9 * DX[0]))
  {
    box_vel.setZero();
    box_vel[0] = -DX[0] / dt;
    box_disp_ = 0.0;
  }
  else
    box_vel.setZero();

  hydro_force_->updateStructureDomain(box_vel, dt, patch_hierarchy_, 0);
  hydro_force_->computeLaggedMomentumIntegral(
    u_idx_, patch_hierarchy_, navier_stokes_integrator_->getVelocityBoundaryConditions());
  time_integrator_->advanceHierarchy(dt);

  pout << "\n";
  pout << "At end       of timestep # " << iteration_num_ << "\n";
  pout << "Simulation time is " << loop_time_ << "\n";
  pout << "+++++++++++++++++++++++++++++++++++++++++++++++++++\n";
  pout << "\n";

  IBTK::Vector3d eel_mom, eel_rot_mom;
  eel_mom.setZero();
  eel_rot_mom.setZero();
  std::vector<std::vector<double> > structure_linear_momentum = ib_method_ops_->getStructureMomentum();
  for (int d = 0; d < NDIM; ++d) eel_mom[d] = structure_linear_momentum[0][d];
  std::vector<std::vector<double> > structure_rotational_momentum =
    ib_method_ops_->getStructureRotationalMomentum();
  for (int d = 0; d < 3; ++d) eel_rot_mom[d] = structure_rotational_momentum[0][d];

  hydro_force_->updateStructureMomentum(eel_mom, eel_rot_mom, 0);
  hydro_force_->computeHydrodynamicForce(
    u_idx_,
    p_idx_,
    -1,
    patch_hierarchy_,
    dt,
    navier_stokes_integrator_->getVelocityBoundaryConditions(),
    navier_stokes_integrator_->getPressureBoundaryConditions());
  hydro_force_->postprocessIntegrateData(current_time, new_time);
  hydro_force_->updateStructurePlotData(patch_hierarchy_, 0);

  structure_COM_ = ib_method_ops_->getCurrentStructureCOM();
  for (int d = 0; d < 3; ++d) eel_COM_[d] = structure_COM_[0][d];
  hydro_force_->setTorqueOrigin(eel_COM_, 0);

  if (near_wall_) {
    const double angle = currentBodyAxisAngle();
    angular_velocity_ = std::atan2(std::sin(angle-last_angle_), std::cos(angle-last_angle_))/dt;
    last_angle_ = angle;
  }

  iteration_num_ += 1;
  const bool last_step = !time_integrator_->stepsRemaining();
  if (dump_viz_data_ && uses_visit_ &&
      (iteration_num_ % viz_dump_interval_ == 0 || last_step))
  {
    pout << "\nWriting visualization files...\n\n";
    writeVisualizationData();
  }
  if (dump_restart_data_ &&
      (iteration_num_ % restart_dump_interval_ == 0 || last_step))
  {
    pout << "\nWriting restart files...\n\n";
    RestartManager::getManager()->writeRestartFile(restart_dump_dirname_, iteration_num_);
  }
  if (dump_timer_data_ &&
      (iteration_num_ % timer_dump_interval_ == 0 || last_step))
  {
    pout << "\nWriting timer data...\n\n";
    TimerManager::getManager()->print(plog);
  }
  if (dump_postproc_data_ &&
      (iteration_num_ % postproc_data_dump_interval_ == 0 || last_step))
  {
    output_data(patch_hierarchy_,
                navier_stokes_integrator_,
                ib_method_ops_->getLDataManager(),
                iteration_num_,
                loop_time_,
                postproc_data_dump_dirname_);
  }
}

void
EelEnvironment::Impl::shutdown()
{
  if (shutdown_started_) return;
  shutdown_started_ = true;
  ready_ = false;

  for (RobinBcCoefStrategy<NDIM>* coefficient : u_bc_coefs_) delete coefficient;
  u_bc_coefs_.clear();

  hydro_force_.setNull();
  ib_kinematics_op_.setNull();
  ibkinematics_ops_vec_.clear();
  silo_data_writer_.setNull();
  visit_data_writer_.setNull();
  f_fcn_.setNull();
  p_init_.setNull();
  u_init_.setNull();
  ib_force_fcn_.setNull();
  ib_initializer_.setNull();
  gridding_algorithm_.setNull();
  load_balancer_.setNull();
  box_generator_.setNull();
  error_detector_.setNull();
  patch_hierarchy_.setNull();
  grid_geometry_.setNull();
  time_integrator_.setNull();
  ib_method_ops_.setNull();
  navier_stokes_integrator_.setNull();
  input_db_.setNull();
  app_initializer_.setNull();

  u_var_.setNull();
  probe_u_var_.setNull();

  ibtk_init_.reset();
  environment_comm_ = MPI_COMM_NULL;
}

EelEnvironment::EelEnvironment() : impl_(new Impl()) {}

EelEnvironment::~EelEnvironment() = default;

void
EelEnvironment::initialize(MPI_Comm environment_comm, const std::string& input_file)
{
  impl_->initialize(environment_comm, input_file);
}

void
EelEnvironment::advanceOneStep()
{
  impl_->advanceOneStep();
}

void
EelEnvironment::setTailBeatFrequencyRatio(const double ratio)
{
  impl_->setTailBeatFrequencyRatio(ratio);
}

ControlIntervalResult
EelEnvironment::advanceControlInterval(const double nominal_duration)
{
  return impl_->advanceControlInterval(nominal_duration);
}

double
EelEnvironment::currentTime() const
{
  return impl_->currentTime();
}

std::array<double, 2>
EelEnvironment::currentCenterOfMass() const
{
  return impl_->currentCenterOfMass();
}

double
EelEnvironment::currentTailBeatPhase() const
{
  return impl_->currentTailBeatPhase();
}

double
EelEnvironment::currentTailBeatFrequencyRatio() const
{
  return impl_->currentTailBeatFrequencyRatio();
}

std::size_t
EelEnvironment::globalLagrangianPointCount() const
{
  return impl_->globalLagrangianPointCount();
}

void EelEnvironment::initializeNearWall(MPI_Comm communicator, const std::string& input,
                                       const NearWallConfig& config, double height,
                                       const std::string& restart_directory)
{
  impl_->initialize(communicator, input, &config, height, restart_directory);
}

void EelEnvironment::writeRestart(const std::string& directory)
{ impl_->writeRestart(directory); }

NearWallObservation EelEnvironment::nearWallObservation() const
{ return impl_->nearWallObservation(); }

double EelEnvironment::currentForceX() const
{ return impl_->currentForceX(); }

double
EelEnvironment::currentBodyAxisAngle() const
{
  return impl_->currentBodyAxisAngle();
}

EelVelocityProbeSample
EelEnvironment::sampleVelocityProbes()
{
  return impl_->sampleVelocityProbes();
}

void
EelEnvironment::writeVisualizationSnapshot()
{
  impl_->writeVisualizationSnapshot();
}

bool
EelEnvironment::stepsRemaining() const
{
  return impl_->stepsRemaining();
}

void
EelEnvironment::shutdown()
{
  impl_->shutdown();
}

namespace
{

void
output_data(Pointer<PatchHierarchy<NDIM> > patch_hierarchy,
            Pointer<INSHierarchyIntegrator> navier_stokes_integrator,
            LDataManager* l_data_manager,
            const int iteration_num,
            const double loop_time,
            const string& data_dump_dirname)
{
  plog << "writing hierarchy data at iteration " << iteration_num << " to disk" << endl;
  plog << "simulation time is " << loop_time << endl;

  string file_name = data_dump_dirname + "/" + "hier_data.";
  char temp_buf[128];
  std::snprintf(temp_buf, sizeof(temp_buf), "%05d.samrai.%05d", iteration_num, IBTK_MPI::getRank());
  file_name += temp_buf;
  Pointer<HDFDatabase> hier_db = new HDFDatabase("hier_db");
  hier_db->create(file_name);
  VariableDatabase<NDIM>* var_db = VariableDatabase<NDIM>::getDatabase();
  ComponentSelector hier_data;
  hier_data.setFlag(var_db->mapVariableAndContextToIndex(
    navier_stokes_integrator->getVelocityVariable(),
    navier_stokes_integrator->getCurrentContext()));
  hier_data.setFlag(var_db->mapVariableAndContextToIndex(
    navier_stokes_integrator->getPressureVariable(),
    navier_stokes_integrator->getCurrentContext()));
  patch_hierarchy->putToDatabase(hier_db->putDatabase("PatchHierarchy"), hier_data);
  hier_db->putDouble("loop_time", loop_time);
  hier_db->putInteger("iteration_num", iteration_num);
  hier_db->close();

  const int finest_hier_level = patch_hierarchy->getFinestLevelNumber();
  Pointer<LData> X_data = l_data_manager->getLData("X", finest_hier_level);
  Vec X_petsc_vec = X_data->getVec();
  Vec X_lag_vec;
  VecDuplicate(X_petsc_vec, &X_lag_vec);
  l_data_manager->scatterPETScToLagrangian(X_petsc_vec, X_lag_vec, finest_hier_level);
  file_name = data_dump_dirname + "/" + "X.";
  std::snprintf(temp_buf, sizeof(temp_buf), "%05d", iteration_num);
  file_name += temp_buf;
  PetscViewer viewer;
  PetscViewerASCIIOpen(PETSC_COMM_WORLD, file_name.c_str(), &viewer);
  VecView(X_lag_vec, viewer);
  PetscViewerDestroy(&viewer);
  VecDestroy(&X_lag_vec);
}

} // namespace
} // namespace eel2d
} // namespace ibamr_smarties
