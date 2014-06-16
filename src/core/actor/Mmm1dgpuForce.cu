#include "actor/Mmm1dgpuForce.hpp"
#include "cuda_utils.hpp"

#ifdef MMM1D_GPU

Mmm1dgpuForce *mmm1dgpuForce = 0;

// the code is mostly multi-GPU capable, but Espresso is not yet
const int deviceCount = 1;
float multigpu_factors[] = {1.0};
#define cudaSetDevice(d)
#define HANDLE_ERROR(a) cuda_safe_mem(a) // TODO: inline

#include "mmm-common_cuda.hpp"
#include "mmm1d.hpp"
#include "grid.hpp"
#include "interaction_data.hpp"
#include "forces.hpp"
#include "EspressoSystemInterface.hpp"

void addMmm1dgpuForce(double maxPWerror, double switch_rad, int bessel_cutoff)
{
	static Mmm1dgpuForce *mmm1dgpuForce = NULL;
	if (!mmm1dgpuForce) // inter coulomb mmm1dgpu was never called before
	{
		printf("Creating Mmm1dgpuForce with %f %f %d\n", maxPWerror, switch_rad, bessel_cutoff );
		// coulomb prefactor gets updated in Mmm1dgpuForce::run()
		mmm1dgpuForce = new Mmm1dgpuForce(espressoSystemInterface, 0, maxPWerror, switch_rad, bessel_cutoff);
		potentials.push_back(mmm1dgpuForce);
	}
	else // we only need to update the parameters
	{
		printf("Updating Mmm1dgpuForce with %f %f %d\n", maxPWerror, switch_rad, bessel_cutoff );
		mmm1dgpuForce->set_params(0, 0, maxPWerror, switch_rad, bessel_cutoff);
	}
}

__device__ inline void atomicadd(float* address, float value)
{
#if !defined __CUDA_ARCH__ || __CUDA_ARCH__ >= 200
  atomicAdd(address, value);
#elif __CUDA_ARCH__ >= 110
	int oldval, newval, readback;
	oldval = __float_as_int(*address);
	newval = __float_as_int(__int_as_float(oldval) + value);
	while ((readback=atomicCAS((int *)address, oldval, newval)) != oldval)
	{
		oldval = readback;
		newval = __float_as_int(__int_as_float(oldval) + value);
	}
#else
#error atomicAdd needs compute capability 1.1 or higher
#endif
}

const mmm1dgpu_real C_GAMMAf = C_GAMMA;
const mmm1dgpu_real C_2PIf = C_2PI;

__constant__ mmm1dgpu_real far_switch_radius_2 = 0.05*0.05;
__constant__ mmm1dgpu_real boxz;
__constant__ mmm1dgpu_real uz;
__constant__ mmm1dgpu_real coulomb_prefactor = 1.0;
__constant__ int bessel_cutoff = 5;
__constant__ mmm1dgpu_real maxPWerror = 1e-5;

Mmm1dgpuForce::Mmm1dgpuForce(SystemInterface &s, mmm1dgpu_real _coulomb_prefactor, mmm1dgpu_real _maxPWerror,
	mmm1dgpu_real _far_switch_radius, int _bessel_cutoff)
:coulomb_prefactor(_coulomb_prefactor), maxPWerror(_maxPWerror), far_switch_radius(_far_switch_radius),
	bessel_cutoff(_bessel_cutoff), host_boxz(0), host_npart(0), pairs(-1), dev_forcePairs(NULL), dev_energyBlocks(NULL),
	numThreads(64), need_tune(true)
{
	// interface sanity checks
	if(!s.requestFGpu())
		std::cerr << "Mmm1dgpuForce needs access to forces on GPU!" << std::endl;

	if(!s.requestRGpu())
		std::cerr << "Mmm1dgpuForce needs access to positions on GPU!" << std::endl;

	if(!s.requestQGpu())
		std::cerr << "Mmm1dgpuForce needs access to charges on GPU!" << std::endl;

	// system sanity checks
	if (PERIODIC(0) || PERIODIC(1) || !PERIODIC(2))
	{
		std::cerr << "MMM1D requires periodicity (0,0,1)" << std::endl;
		exit(EXIT_FAILURE);
	}

	// turn on MMM1DGPU
	coulomb.method = COULOMB_MMM1D_GPU;
	mpi_bcast_coulomb_params();
	modpsi_init();
}

void Mmm1dgpuForce::setup(SystemInterface &s)
{
	if (s.box()[2] <= 0)
	{
		std::cerr << "Error: Please set box length before initializing MMM1D!" << std::endl;
		exit(EXIT_FAILURE);
	}
	if (need_tune == true && s.npart_gpu() > 0)
	{
		printf("Tuning in setup. %f %f %f %d\n", coulomb_prefactor, maxPWerror, far_switch_radius, bessel_cutoff);
		set_params(s.box()[2], coulomb_prefactor, maxPWerror, far_switch_radius, bessel_cutoff);
		tune(s, maxPWerror, far_switch_radius, bessel_cutoff);
	}
	if (s.box()[2] != host_boxz)
	{
		set_params(s.box()[2], 0,-1,-1,-1);
	}
	if (s.npart_gpu() == host_npart) // unchanged
	{
		return;
	}

	// For all but the largest systems, it is faster to store force pairs and then sum them up.
	// Atomics are just so slow: so unless we're limited by memory, do the latter.
	pairs = 2;
	for (int d = 0; d < deviceCount; d++)
	{
		cudaSetDevice(d);

		size_t freeMem, totalMem;
		cudaMemGetInfo(&freeMem, &totalMem);
		if (freeMem/2 < 3*s.npart_gpu()*s.npart_gpu()*sizeof(mmm1dgpu_real)) // don't use more than half the device's memory
		{
			std::cerr << "Switching to atomicAdd due to memory constraints." << std::endl;
			pairs = 0;
			break;
		}
	}
	if (dev_forcePairs)
		cudaFree(dev_forcePairs);
	if (pairs) // we need memory to store force pairs
	{
		printf("Allocating %d bytes of memory for vector reduction\n", 3*s.npart_gpu()*s.npart_gpu()*sizeof(mmm1dgpu_real));
		HANDLE_ERROR( cudaMalloc((void**)&dev_forcePairs, 3*s.npart_gpu()*s.npart_gpu()*sizeof(mmm1dgpu_real)) );
	}
	if (dev_energyBlocks)
		cudaFree(dev_energyBlocks);
	HANDLE_ERROR( cudaMalloc((void**)&dev_energyBlocks, numBlocks(s)*sizeof(mmm1dgpu_real)) );
	host_npart = s.npart_gpu();
}

unsigned int Mmm1dgpuForce::numBlocks(SystemInterface &s)
{
	int b = s.npart_gpu()*s.npart_gpu()/numThreads+1;
	if (b > 65535)
		b = 65535;
	return b;
}

Mmm1dgpuForce::~Mmm1dgpuForce()
{
	modpsi_destroy();
	cudaFree(dev_forcePairs);

	if (coulomb.method == COULOMB_MMM1D_GPU)
	{
		coulomb.method = COULOMB_NONE;
		mpi_bcast_coulomb_params();
	}
}

__forceinline__ __device__ mmm1dgpu_real sqpow(mmm1dgpu_real x)
{
	return pow(x,2);
}
__forceinline__ __device__ mmm1dgpu_real cbpow(mmm1dgpu_real x)
{
	return pow(x,3);
}

__device__ void sumReduction(mmm1dgpu_real *input, mmm1dgpu_real *sum)
{
	int tid = threadIdx.x;
	for (int i = blockDim.x/2; i > 0; i /= 2)
	{
		__syncthreads();
		if (tid < i)
			input[tid] += input[i+tid];
	}
	__syncthreads();
	if (tid == 0)
		sum[0] = input[0];
}

__global__ void sumKernel(mmm1dgpu_real *data, int N)
{
	extern __shared__ mmm1dgpu_real partialsums[];
	if (blockIdx.x != 0) return;
	int tid = threadIdx.x;
	mmm1dgpu_real result = 0;
	
	for (int i = 0; i < N; i += blockDim.x)
	{
		if (i+tid >= N)
			partialsums[tid] = 0;
		else
			partialsums[tid] = data[i+tid];
		
		sumReduction(partialsums, &result);
		if (tid == 0)
		{
			if (i == 0) data[0] = 0;
			data[0] += result;
		}
	}
}

__global__ void besselTuneKernel(int *result, mmm1dgpu_real far_switch_radius, int maxCut)
{
	mmm1dgpu_real arg = C_2PIf*uz*far_switch_radius;
	mmm1dgpu_real pref = 4*uz*max(1.0f, C_2PIf*uz);
	mmm1dgpu_real err;
	int P = 1;
	do
	{
		err = pref*dev_K1(arg*P)*exp(arg)/arg*(P-1 + 1/arg);
		P++;
	} while (err > maxPWerror && P <= maxCut);
	P--;

	result[0] = P;
}

void Mmm1dgpuForce::tune(SystemInterface &s, mmm1dgpu_real _maxPWerror, mmm1dgpu_real _far_switch_radius, int _bessel_cutoff)
{
	mmm1dgpu_real far_switch_radius = _far_switch_radius;
	int bessel_cutoff = _bessel_cutoff;
	mmm1dgpu_real maxrad = host_boxz;

	if (_far_switch_radius < 0 && _bessel_cutoff < 0)
	// autodetermine switching and bessel cutoff radius
	{
		mmm1dgpu_real bestrad = 0, besttime = INFINITY;

		for (far_switch_radius = 0.05*maxrad; far_switch_radius < maxrad; far_switch_radius += 0.05*maxrad)
		{
			set_params(0, 0, _maxPWerror, far_switch_radius, bessel_cutoff);
			tune(s, _maxPWerror, far_switch_radius, -2); // tune bessel cutoff
			int runtime = force_benchmark(s);
			if (runtime < besttime)
			{
				besttime = runtime;
				bestrad = far_switch_radius;
			}
		}
		far_switch_radius = bestrad;

		set_params(0, 0, _maxPWerror, far_switch_radius, bessel_cutoff);
		tune(s, _maxPWerror, far_switch_radius, -2); // tune bessel cutoff
	}

	else if (_bessel_cutoff < 0)
	// autodetermine bessel cutoff
	{
		int *dev_cutoff;
		int maxCut = 30;
		HANDLE_ERROR( cudaMalloc((void**)&dev_cutoff, sizeof(int)) );
		besselTuneKernel<<<1,1>>>(dev_cutoff, far_switch_radius, maxCut);
		HANDLE_ERROR( cudaMemcpy(&bessel_cutoff, dev_cutoff, sizeof(int), cudaMemcpyDeviceToHost) );
		cudaFree(dev_cutoff);
		if (_bessel_cutoff != -2 && bessel_cutoff >= maxCut) // we already have our switching radius and only need to determine the cutoff, i.e. this is the final tuning round
		{
			std::cerr << "No reasonable Bessel cutoff could be determined." << std::endl;
			exit(EXIT_FAILURE);
		}

		set_params(0, 0, _maxPWerror, far_switch_radius, bessel_cutoff);
	}
}

void Mmm1dgpuForce::set_params(mmm1dgpu_real _boxz, mmm1dgpu_real _coulomb_prefactor, mmm1dgpu_real _maxPWerror, mmm1dgpu_real _far_switch_radius, int _bessel_cutoff)
{
	printf("Setting %f %f %f %f %d\n",_boxz,_coulomb_prefactor,_maxPWerror,_far_switch_radius,_bessel_cutoff);
	if (_boxz > 0 && _far_switch_radius > _boxz)
	{
		printf("Far switch radius (%f) must not be larger than the box length (%f).\n", _far_switch_radius, _boxz);
		exit(EXIT_FAILURE);
	}
	mmm1dgpu_real _far_switch_radius_2 = _far_switch_radius*_far_switch_radius;
	mmm1dgpu_real _uz = 1.0/_boxz;
	for (int d = 0; d < deviceCount; d++)
	{
		// double colons are needed to access the constant memory variables because they
		// are file globals and we have identically named class variables
		cudaSetDevice(d);
		if (_far_switch_radius >= 0)
		{
			HANDLE_ERROR( cudaMemcpyToSymbol(::far_switch_radius_2, &_far_switch_radius_2, sizeof(mmm1dgpu_real)) );
			mmm1d_params.far_switch_radius_2 = _far_switch_radius*_far_switch_radius;
			far_switch_radius = _far_switch_radius;
		}
		if (_boxz > 0)
		{
			host_boxz = _boxz;
			HANDLE_ERROR( cudaMemcpyToSymbol(::boxz, &_boxz, sizeof(mmm1dgpu_real)) );
			HANDLE_ERROR( cudaMemcpyToSymbol(::uz, &_uz, sizeof(mmm1dgpu_real)) );
		}
		if (_coulomb_prefactor != 0)
		{
			HANDLE_ERROR( cudaMemcpyToSymbol(::coulomb_prefactor, &_coulomb_prefactor, sizeof(mmm1dgpu_real)) );
			coulomb_prefactor = _coulomb_prefactor;
		}
		if (_bessel_cutoff > 0)
		{
			HANDLE_ERROR( cudaMemcpyToSymbol(::bessel_cutoff, &_bessel_cutoff, sizeof(int)) );
			mmm1d_params.bessel_cutoff = _bessel_cutoff;
			bessel_cutoff = _bessel_cutoff;
		}
		if (_maxPWerror > 0)
		{
			HANDLE_ERROR( cudaMemcpyToSymbol(::maxPWerror, &_maxPWerror, sizeof(mmm1dgpu_real)) );
			mmm1d_params.maxPWerror = _maxPWerror;
			maxPWerror = _maxPWerror;
		}
	}
	need_tune = true;
}

__global__ void forcesKernel(const __restrict__ mmm1dgpu_real *r, const __restrict__ mmm1dgpu_real *q, __restrict__ mmm1dgpu_real *force, int N, int pairs, int tStart = 0, int tStop = -1)
{
	if (tStop < 0)
		tStop = N*N;

	for (int tid = threadIdx.x + blockIdx.x * blockDim.x + tStart; tid < tStop; tid += blockDim.x * gridDim.x)
	{
		int p1 = tid%N, p2 = tid/N;
		mmm1dgpu_real x = r[3*p2] - r[3*p1], y = r[3*p2+1] - r[3*p1+1], z = r[3*p2+2] - r[3*p1+2];
		mmm1dgpu_real rxy2 = sqpow(x) + sqpow(y);
		mmm1dgpu_real rxy = sqrt(rxy2);
		mmm1dgpu_real sum_r = 0, sum_z = 0;
		
//		if (boxz <= 0.0) return; // otherwise we'd get into an infinite loop if we're not initialized correctly

		while (fabs(z) > boxz/2) // make sure we take the shortest distance
			z -= (z > 0? 1 : -1)*boxz;

		if (p1 == p2) // particle exerts no force on itself
		{
			rxy = 1; // so the division at the end doesn't fail with NaN (sum_r is 0 anyway)
		}
		else if (rxy2 <= far_switch_radius_2) // near formula
		{
			mmm1dgpu_real uzz = uz*z;
			mmm1dgpu_real uzr = uz*rxy;
			sum_z = dev_mod_psi_odd(0, uzz);
			mmm1dgpu_real uzrpow = uzr;
			for (int n = 1; n < device_n_modPsi; n++)
			{
				mmm1dgpu_real sum_r_old = sum_r;
				mmm1dgpu_real mpe = dev_mod_psi_even(n, uzz);
     			mmm1dgpu_real mpo = dev_mod_psi_odd(n, uzz);

     			sum_r += 2*n*mpe * uzrpow;
     			uzrpow *= uzr;
     			sum_z += mpo * uzrpow;
     			uzrpow *= uzr;

     			if (fabs(sum_r_old - sum_r) < maxPWerror)
					break;
			}

			sum_r *= sqpow(uz);
			sum_z *= sqpow(uz);

			sum_r += rxy*cbpow(rsqrt(rxy2+pow(z,2)));
			sum_r += rxy*cbpow(rsqrt(rxy2+pow(z+boxz,2)));
			sum_r += rxy*cbpow(rsqrt(rxy2+pow(z-boxz,2)));

			sum_z += z*cbpow(rsqrt(rxy2+pow(z,2)));
			sum_z += (z+boxz)*cbpow(rsqrt(rxy2+pow(z+boxz,2)));
			sum_z += (z-boxz)*cbpow(rsqrt(rxy2+pow(z-boxz,2)));

			if (rxy == 0) // particles at the same radial position only exert a force in z direction
			{
				rxy = 1;  // so the division at the end doesn't fail with NaN (sum_r is 0 anyway)
			}
		}
		else // far formula
		{
			for (int p = 1; p < bessel_cutoff; p++)
			{
				mmm1dgpu_real arg = C_2PIf*uz*p;
				sum_r += p*dev_K1(arg*rxy)*cos(arg*z);
				sum_z += p*dev_K0(arg*rxy)*sin(arg*z);
			}
			sum_r *= sqpow(uz)*4*C_2PIf;
			sum_z *= sqpow(uz)*4*C_2PIf;
			sum_r += 2*uz/rxy;
		}

		mmm1dgpu_real pref = coulomb_prefactor*q[p1]*q[p2];
		if (pairs)
		{
			force[3*(p1+p2*N-tStart)] = pref*sum_r/rxy*x;
			force[3*(p1+p2*N-tStart)+1] = pref*sum_r/rxy*y;
			force[3*(p1+p2*N-tStart)+2] = pref*sum_z;
		}
		else
		{
#ifdef ELECTROSTATICS_GPU_DOUBLE_PRECISION
			atomicadd8(&force[3*p2], pref*sum_r/rxy*x);
			atomicadd8(&force[3*p2+1], pref*sum_r/rxy*y);
			atomicadd8(&force[3*p2+2], pref*sum_z);
#else
			atomicadd(&force[3*p2], pref*sum_r/rxy*x);
			atomicadd(&force[3*p2+1], pref*sum_r/rxy*y);
			atomicadd(&force[3*p2+2], pref*sum_z);
#endif
		}
	}
}

__global__ void energiesKernel(const __restrict__ mmm1dgpu_real *r, const __restrict__ mmm1dgpu_real *q, __restrict__ mmm1dgpu_real *energy, int N, int pairs, int tStart = 0, int tStop = -1)
{
	if (tStop < 0)
		tStop = N*N;

	extern __shared__ mmm1dgpu_real partialsums[];
	if (!pairs)
	{
		partialsums[threadIdx.x] = 0;
		__syncthreads();
	}
	for (int tid = threadIdx.x + blockIdx.x * blockDim.x + tStart; tid < tStop; tid += blockDim.x * gridDim.x)
	{
		int p1 = tid%N, p2 = tid/N;
		mmm1dgpu_real z = r[3*p2+2] - r[3*p1+2];
		mmm1dgpu_real rxy2 = sqpow(r[3*p2] - r[3*p1]) + sqpow(r[3*p2+1] - r[3*p1+1]);
		mmm1dgpu_real rxy = sqrt(rxy2);
		mmm1dgpu_real sum_e = 0;

//		if (boxz <= 0.0) return; // otherwise we'd get into an infinite loop if we're not initialized correctly

		while (fabs(z) > boxz/2) // make sure we take the shortest distance
			z -= (z > 0? 1 : -1)*boxz;

		if (p1 == p2) // particle exerts no force on itself
		{
		}
		else if (rxy2 <= far_switch_radius_2) // near formula
		{
			mmm1dgpu_real uzz = uz*z;
			mmm1dgpu_real uzr2 = sqpow(uz*rxy);
			mmm1dgpu_real uzrpow = uzr2;
			sum_e = dev_mod_psi_even(0, uzz);
			for (int n = 1; n < device_n_modPsi; n++)
			{
				mmm1dgpu_real sum_e_old = sum_e;
				mmm1dgpu_real mpe = dev_mod_psi_even(n, uzz);
     			sum_e += mpe * uzrpow;
     			uzrpow *= uzr2;
				
				if (fabs(sum_e_old - sum_e) < maxPWerror)
					break;
			}

			sum_e *= -1*uz;
			sum_e -= 2*uz*C_GAMMAf;
			sum_e += rsqrt(rxy2+sqpow(z));
			sum_e += rsqrt(rxy2+sqpow(z+boxz));
			sum_e += rsqrt(rxy2+sqpow(z-boxz));
		}
		else // far formula
		{
			sum_e = -(log(rxy*uz/2) + C_GAMMAf)/2;
			for (int p = 1; p < bessel_cutoff; p++)
			{
				mmm1dgpu_real arg = C_2PIf*uz*p;
				sum_e += dev_K0(arg*rxy)*cos(arg*z);
			}
			sum_e *= uz*4;
		}

		if (pairs)
		{
			energy[p1+p2*N-tStart] = coulomb_prefactor*q[p1]*q[p2]*sum_e;
		}
		else
		{
			partialsums[threadIdx.x] += coulomb_prefactor*q[p1]*q[p2]*sum_e;
		}
	}
	if (!pairs)
	{
		sumReduction(partialsums, &energy[blockIdx.x]);
	}
}

__global__ void vectorReductionKernel(mmm1dgpu_real *src, mmm1dgpu_real *dst, int N, int tStart = 0, int tStop = -1)
{
	if (tStop < 0)
		tStop = N*N;

	for (int tid = threadIdx.x + blockIdx.x * blockDim.x; tid < N; tid += blockDim.x * gridDim.x)
	{
		int offset = ((tid + (tStart % N)) % N);
		
		for (int i = 0; tid+i*N < (tStop - tStart); i++)
		{
			#pragma unroll 3
			for (int d = 0; d<3; d++)
			{
				dst[3*offset+d] -= src[3*(tid+i*N)+d];
			}
		}
	}
}

void Mmm1dgpuForce::computeForces(SystemInterface &s)
{
	if (coulomb.method != COULOMB_MMM1D_GPU) // MMM1DGPU was disabled. nobody cares about our calculations anymore
	{
		std::cerr << "MMM1D: coulomb.method has been changed, skipping calculation" << std::endl;
		return;
	}
	setup(s);

	if (pairs < 0)
	{
		std::cerr << "MMM1D was not initialized correctly" << std::endl;
		exit(EXIT_FAILURE);
	}

	if (pairs) // if we calculate force pairs, we need to reduce them to forces
	{
		int blocksRed = s.npart_gpu()/numThreads+1;
		KERNELCALL(forcesKernel,numBlocks(s),numThreads,(s.rGpuBegin(), s.qGpuBegin(), dev_forcePairs, s.npart_gpu(), pairs))
		KERNELCALL(vectorReductionKernel,blocksRed,numThreads,(dev_forcePairs, s.fGpuBegin(), s.npart_gpu()))
	}
	else
	{
		KERNELCALL(forcesKernel,numBlocks(s),numThreads,(s.rGpuBegin(), s.qGpuBegin(), s.fGpuBegin(), s.npart_gpu(), pairs))
	}
}

/*
void Mmm1dgpuForce::computeEnergy(SystemInterface &s) // TODO: this is not yet tested
{
	if (pairs < 0)
	{
		std::cerr << "MMM1D was not initialized correctly" << std::endl;
		exit(EXIT_FAILURE);
	}
	int shared = numThreads*sizeof(mmm1dgpu_real);

	KERNELCALL_shared(energiesKernel,numBlocks(s),numThreads,shared,(s.rGpuBegin(), s.qGpuBegin(), dev_energyBlocks, s.npart_gpu(), pairs));
	KERNELCALL_shared(sumKernel,1,numThreads,shared,(dev_energyBlocks, numBlocks(s)));
	HANDLE_ERROR( cudaMemcpyAsync(&dev_energyBlocks, s.eGpuBegin(), sizeof(mmm1dgpu_real), cudaMemcpyDeviceToDevice, stream[0]) );
}
*/

float Mmm1dgpuForce::force_benchmark(SystemInterface &s)
{
	printf("Doing force benchmark\n");
	cudaEvent_t eventStart, eventStop;
	cudaStream_t stream;
	float elapsedTime;

	cudaStreamCreate(&stream);
	HANDLE_ERROR( cudaEventCreate(&eventStart) );
	HANDLE_ERROR( cudaEventCreate(&eventStop) );
	HANDLE_ERROR( cudaEventRecord(eventStart, stream) );
	//KERNELCALL(forcesKernel,numBlocks(s),numThreads,(s.rGpuBegin(), s.qGpuBegin(), s.fGpuBegin(), s.npart_gpu(), 0))
	forcesKernel<<<numBlocks(s),numThreads>>>(s.rGpuBegin(), s.qGpuBegin(), s.fGpuBegin(), s.npart_gpu(), 0);
	HANDLE_ERROR( cudaEventRecord(eventStop, stream) );
	HANDLE_ERROR( cudaEventSynchronize(eventStop) );
	HANDLE_ERROR( cudaEventElapsedTime(&elapsedTime, eventStart, eventStop) );
	printf(">>> Calculated in %3.3f ms\n", elapsedTime);
	HANDLE_ERROR( cudaEventDestroy(eventStart) );
	HANDLE_ERROR( cudaEventDestroy(eventStop) );

	return elapsedTime;
}

#endif /* MMM1D_GPU */
