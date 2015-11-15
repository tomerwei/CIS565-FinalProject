#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <math.h>
#include <glm/glm.hpp>
#include "utilityCore.hpp"
#include "kernel.h"

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

#define sign(x) (x>0)-(x<0)

/**
 * Check for CUDA errors; print and exit if there was a problem.
 */
void checkCUDAError(const char *msg, int line = -1) {
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess != err) {
        if (line >= 0) {
            fprintf(stderr, "Line %d: ", line);
        }
        fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }
}


/*****************
 * Configuration *
 *****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

/*! Mass of one "planet." */
#define robotRadius 1


/***********************************************
 * Kernel state (pointers are device pointers) *
 ***********************************************/

int numAgents;
dim3 threadsPerBlock(blockSize);

float scene_scale = 100.0;

struct agent{
	glm::vec3 pos;
	glm::vec3 vel;
	glm::vec3 goal;
	float radius;
};

glm::vec3 *dev_pos;

agent *dev_agents;

/******************
 * initSimulation *
 ******************/

__host__ __device__ unsigned int hash(unsigned int a) {
    a = (a + 0x7ed55d16) + (a << 12);
    a = (a ^ 0xc761c23c) ^ (a >> 19);
    a = (a + 0x165667b1) + (a << 5);
    a = (a + 0xd3a2646c) ^ (a << 9);
    a = (a + 0xfd7046c5) + (a << 3);
    a = (a ^ 0xb55a4f09) ^ (a >> 16);
    return a;
}

/**
 * Function for generating a random vec3.
 */
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
    thrust::default_random_engine rng(hash((int)(index * time)));
    thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

    return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

__global__ void kernInitAgents(int N, agent* agents, float scale, float radius){
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < N){
		float rad = ((float)index / (float)N) * (2.0f * 3.1415f);
		agents[index].pos.x = scale * radius * cos(rad);
		agents[index].pos.y = scale * radius * sin(rad);
		agents[index].pos.z = 0.0;
		agents[index].goal = -agents[index].pos;
	}
}

/**
 * Initialize memory, update some globals
 */
void Nbody::initSimulation(int N) {
	//N = 5;
	numAgents = N;
    dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

    cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
    checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

	cudaMalloc((void**)&dev_agents, N*sizeof(agent));
	checkCUDAErrorWithLine("cudaMalloc dev_goals failed!");

	kernInitAgents<<<fullBlocksPerGrid, blockSize>>>(numAgents, dev_agents, scene_scale, 0.5);
	checkCUDAErrorWithLine("kernInitAgents failed!");

    cudaThreadSynchronize();
}

/******************
 * copyPlanetsToVBO *
 ******************/

/**
 * Copy the planet positions into the VBO so that they can be drawn by OpenGL.
 */
__global__ void kernCopyPlanetsToVBO(int N, glm::vec3 *pos, float *vbo, float s_scale) {
    int index = threadIdx.x + (blockIdx.x * blockDim.x);

    float c_scale = -1.0f / s_scale;

    if (index < N) {
        vbo[4 * index + 0] = pos[index].x * c_scale;
        vbo[4 * index + 1] = pos[index].y * c_scale;
        vbo[4 * index + 2] = pos[index].z * c_scale;
        vbo[4 * index + 3] = 1;
    }
}

/**
 * Wrapper for call to the kernCopyPlanetsToVBO CUDA kernel.
 */
void Nbody::copyPlanetsToVBO(float *vbodptr) {
    dim3 fullBlocksPerGrid((int)ceil(float(numAgents) / float(blockSize)));

    kernCopyPlanetsToVBO<<<fullBlocksPerGrid, blockSize>>>(numAgents, dev_pos, vbodptr, scene_scale);
    checkCUDAErrorWithLine("copyPlanetsToVBO failed!");

    cudaThreadSynchronize();
}

/******************
 * stepSimulation *
 ******************/

__device__ glm::vec3 clearPathVelocity(){

}

__global__ void kernUpdateDesVel(int N, agent *dev_agents){
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < N){
		// Get desired velocity
		dev_agents[index].vel = glm::normalize(dev_agents[index].goal - dev_agents[index].pos);
		if (glm::distance(dev_agents[index].goal, dev_agents[index].pos) < 0.1){
			dev_agents[index].vel = glm::vec3(0.0);
		}
	}
}

__global__ void kernUpdateVel(int N, float dt, agent *dev_agents){
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < N){
		// Get ClearPath adjusted velocity


	}
}

__global__ void kernUpdatePos(int N, float dt, agent *dev_agents, glm::vec3 *dev_pos){
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < N){
		// Update positions
		dev_agents[index].pos = dev_agents[index].pos + dev_agents[index].vel * dt;
		dev_pos[index] = dev_agents[index].pos;
	}
}

/**
 * Step the entire N-body simulation by `dt` seconds.
 */
void Nbody::stepSimulation(float dt) {

	dim3 fullBlocksPerGrid((numAgents + blockSize - 1) / blockSize);

	// Update all the desired velocities
	kernUpdateDesVel<<<fullBlocksPerGrid, blockSize>>>(numAgents, dev_agents);

	// Update the velocities according to ClearPath
	kernUpdateVel<<<fullBlocksPerGrid, blockSize>>>(numAgents, dt, dev_agents);

	// Update the positions
	kernUpdatePos<<<fullBlocksPerGrid, blockSize>>>(numAgents, dt, dev_agents, dev_pos);
}