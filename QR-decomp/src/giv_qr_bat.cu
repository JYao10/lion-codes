/*
 *  Copyright 2013 William J. Brouwer, Pierre-Yves Taunay
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */
 
#include <cuda.h>
#include <cuda_runtime.h>
#include <cuda_runtime_api.h>
#include <cublas_v2.h>

#include "main.h"
#include "utilities.h"

__device__ __constant__ int cmem_size,cmem_size_MM;

__global__ void create_ptr(float2 **q_A,float2 **q_B,float2 **q_C,float2 *q_temp,float2 *q_tempB,float2 *q_complete) {
	int idx = threadIdx.x + blockIdx.x * blockDim.x;
	int mat = idx*MATRIX_SIDE*MATRIX_SIDE;

	__syncthreads();
	if(idx < cmem_size )  
		q_A[idx] = &q_temp[mat];
	__syncthreads();
	if(idx < cmem_size )  
		q_B[idx] = &q_tempB[mat];
	__syncthreads();
	if(idx < cmem_size )  
		q_C[idx] = &q_complete[mat];
}	

__global__ void copy_to_temp(float2 *q_temp, float2 *q_complete) {
	int idx = threadIdx.x + blockIdx.x * blockDim.x + blockIdx.y*blockDim.x*gridDim.x;

	__shared__ float2 buffer[NTH];
	__syncthreads();
	if(idx < cmem_size_MM)
		buffer[threadIdx.x].x = q_complete[idx].x;
	
	__syncthreads();
	if(idx < cmem_size_MM)
		buffer[threadIdx.x].y = q_complete[idx].y;

	__syncthreads();
	if(idx < cmem_size_MM)
		q_temp[idx].x = buffer[threadIdx.x].x;
	__syncthreads();
	if(idx < cmem_size_MM)
		q_temp[idx].y = buffer[threadIdx.x].y;
}	


__device__ float cabs_sq(float2 input){

	return input.x * input.x + input.y * input.y;
}

/* Kernel Overview
 * 
 * One block processes one complex matrix, performing one iteration of the qr
 * decomposition by givens rotations
 * 
 * WJB 07/13
 */
__global__ void qr_gpu_bat(int col, float2 * matrices, float2 *q_temp, float2 *q_complete){
	// values we use to calculate Givens
	__shared__ float2 lower;
	__shared__ float2 upper;

	// buffered c,s elements for constructing G^T contribution
	__shared__ float2 g_sin[ MATRIX_SIDE ];
	__shared__ float2 g_cos[ MATRIX_SIDE ];

	// buffer a row for multiplication
	float2 __shared__ row_left[MATRIX_SIDE];
	
	// index to matrix for processing
	int myMatrix 		= threadIdx.x / MATRIX_SIDE;

	// index to vector for processing
	int vectorIndex 	= threadIdx.x % MATRIX_SIDE;

	// matrix offset for this block
	int memoryStride        = ( blockIdx.x * MATRIX_SIDE * MATRIX_SIDE );

	// an index into cos data
	int cosIndex		= (vectorIndex < MATRIX_SIDE-1) ? MATRIX_SIDE-vectorIndex-2 : 0;

	// elements
	float2 row_ele_upper, row_ele_lower;

	// initialize cos &sin buffers
	g_sin[vectorIndex].x = 0.0f;
	g_sin[vectorIndex].y = 0.0f;
	g_cos[vectorIndex].x = 1.0f;
	g_cos[vectorIndex].y = 0.0f;

	int i=0;
	// init
	row_ele_lower.x = matrices [ global_lower_row ].x;
	row_ele_lower.y = matrices [ global_lower_row ].y;

	int steps = MATRIX_SIDE-1-col;

	float2 c,s;
	float2 tmp2,tmp3;

	//evaluate the sequence of Givens rotations for this column eg., lowest two rows after update :

	//		[     a               b               c               d               e      ]
	//            	[                                                                            ]
	//             	[     f               g               h               i               j      ]
	//             	[                                                                            ]
	//           	[     k               l               m               n               o      ]
	//            	[                                                                            ]
	//             	[c1 p + s11 u    c1 q + s11 v    c1 r + s11 w    c1 s + s11 x    c1 t + s11 y]
	//             	[                                                                            ]
	//           	[s12 p + c1 u    s12 q + c1 v    s12 r + c1 w    s12 s + c1 x    s12 t + c1 y]

	//each thread updates one matrix element, iterate up columns

	//	cx 	== cos; x index is number rotation applied
	//	sxy	== sin; x index is number rotation applied
	//			y index indicates first/second row in Givens rot (second == -complex conjugate of first)



	// main matrix update loops
	for (int i=0; i<steps; i++){

		// load two rows
		__syncthreads();
		row_ele_upper.x 		= matrices [ global_upper_row ].x;
		row_ele_upper.y 		= matrices [ global_upper_row ].y;

		if (vectorIndex == col){
			lower = row_ele_lower;
			upper = row_ele_upper;
		}

		__syncthreads();

		// calculate Givens elements
		float tmpA	= cabs_sq(upper); 	
		float tmpB	= cabs_sq(lower);

		float den	= rsqrt(tmpA+tmpB);

		float2 tmpC;


		float2 sgn	= {1.0,0.0};

		if ((upper.x !=0) && (upper.y != 0)){
			sgn.x	= upper.x * rsqrt(tmpA);
			sgn.y	= -upper.y * rsqrt(tmpA);
		}


		c.x 	= sqrt(tmpA) * den;
		c.y 	= 0.0;

		s.x 	= lower.x * den;
		s.y 	= lower.y * den;

		tmp2.x	= (s.x*sgn.x - s.y*sgn.y);
		s.y	*= sgn.x;
		s.y	+= s.x*sgn.y;
		s.y	*= -1;
		s.x	= tmp2.x;


		//             	[c1 p + s11 u    c1 q + s11 v    c1 r + s11 w    c1 s + s11 x    c1 t + s11 y]
		//             	[                                                                            ]
		//           	[s12 p + c1 u    s12 q + c1 v    s12 r + c1 w    s12 s + c1 x    s12 t + c1 y]


		//apply to elements and write out lower to global, it's done
		//-ve complex conj of sin
		s.x *= -1;
		tmp2.x = (s.x*row_ele_upper.x - s.y*row_ele_upper.y);
		tmp2.x += (c.x*row_ele_lower.x - c.y*row_ele_lower.y);
		tmp2.y = (s.y*row_ele_upper.x + s.x*row_ele_upper.y);
		tmp2.y += (c.y*row_ele_lower.x + c.x*row_ele_lower.y);

		matrices[ global_lower_row ] 		= tmp2;

		__syncthreads();


		s.x	*= -1;
		//update new lower element stored locally (the new upper row, but don't bother
		//with global write back
		tmp2.x = (c.x*row_ele_upper.x - row_ele_upper.y*c.y);
		tmp2.x += (row_ele_lower.x*s.x - row_ele_lower.y*s.y);
		tmp2.y = (row_ele_upper.y*c.x + row_ele_upper.x*c.y);
		tmp2.y += (row_ele_lower.y*s.x + row_ele_lower.x*s.y);
		row_ele_lower.x				= tmp2.x;		
		row_ele_lower.y				= tmp2.y;		

		//cache the calculated rotation
		if (vectorIndex == i){

			g_cos [ rotation_ele_index ] = c;
			g_sin [ rotation_ele_index ] = s;

		}


	}
	i=steps-1;

	//write out final upper row 
	matrices[ global_upper_row ] 		= tmp2;


	__syncthreads();

	//build up contributions to G^T
	//these are orthogonal matrices ie., G^-1 == G^T

	//based on simple sequences in upper-hessenberg form eg., for a 5x5

	//                  [c4     s41 c3    s41 s31 c2    s41 s31 s21 c1    s41 s31 s21 s11]
	//                  [                                                                ]
	//                  [s42    c4 c3     c4 s31 c2     c4 s31 s21 c1     c4 s31 s21 s11 ]
	//                  [                                                                ]
	//                  [ 0      s32        c3 c2         c3 s21 c1         c3 s21 s11   ]
	//                  [                                                                ]
	//                  [ 0       0          s22            c2 c1             c2 s11     ]
	//                  [                                                                ]
	//                  [ 0       0           0              s12                c1       ]


	//	cx 	== cos; x index is number rotation applied
	//	sxy	== sin; x index is number rotation applied
	//			y index indicates first/second row in Givens rot (second == -complex conjugate of first)

	//i==index into global memory (row)
	//j==index into shared memory 

	//create and write lowest row
	//float2 tmp2,tmp3;
	float2 tmp	= {0.0f,0.0f};
	i		= MATRIX_SIDE-1;

	//-ve sin on (diagonal-1)
	tmp.x 		= -(float) sub_diag_mask*g_sin[0].x;
	tmp.y 		= (float) sub_diag_mask*g_sin[0].y;
	//cos term on diagonal
	tmp.x		+= (float) for_diag_mask*g_cos[0].x;
	tmp.y		+= (float) for_diag_mask*g_cos[0].y;
	//write
	q_temp[ global_row ] = tmp;


	//seed second last row
	tmp.x		= 0.0f;
	tmp.y		= 0.0f;
	i		= MATRIX_SIDE-2;
	// c0 term on diagonal
	tmp.x 		= (float) diag_mask*g_cos[0].x;
	tmp.y 		= (float) diag_mask*g_cos[0].y;
	// last row term, s0
	tmp.x		+= (float) last_col_mask*g_sin[0].x;
	tmp.y		+= (float) last_col_mask*g_sin[0].y;

	if (steps>2){	

		//complete and write second last row
		//c1 terms, diagonal and forward
		tmp2.x	= (float) for_diag_mask * g_cos[1].x;
		tmp2.y	= (float) for_diag_mask * g_cos[1].y;
		//tmp.x	= tmp.x*tmp2.x - tmp.y*tmp2.y;
		tmp3.x	= tmp.x*tmp2.x - tmp.y*tmp2.y;
		tmp.y	= tmp.y*tmp2.x + tmp.x*tmp2.y;
		tmp.x	= tmp3.x;

		//s1 term, diagonal -1
		tmp2.x	= -(float) sub_diag_mask * g_sin[1].x;
		tmp2.y	= (float) sub_diag_mask * g_sin[1].y;
		tmp.x	+= tmp2.x;
		tmp.y	+= tmp2.y;

		//write
		q_temp[ global_row ] = tmp;


		//a holder for building up products of sin terms
		float2 mult; 
		mult.x	= (float) last_two_col_mask * g_sin[1].x;
		mult.x	+= (float) !(last_two_col_mask);
		mult.y	= (float) last_two_col_mask * g_sin[1].y;

		//complete and write third last row	
		tmp.x		= 0.0f; 
		tmp.y		= 0.0f; 
		i		= MATRIX_SIDE-3;

		// last column element s0
		tmp.x 		= (float) last_col_mask * g_sin[0].x;
		tmp.y 		= (float) last_col_mask * g_sin[0].y;
		// prior row elements cn,...,c0
		tmp.x 		+= (float) ( for_diag_mask && !last_col_mask ) * g_cos [ cosIndex ].x;
		tmp.y 		+= (float) ( for_diag_mask && !last_col_mask ) * g_cos [ cosIndex ].y;


		tmp3.x		= tmp.x*mult.x-tmp.y*mult.y;
		tmp.y		= tmp.y*mult.x+tmp.x*mult.y;
		tmp.x		= tmp3.x;

		//cos terms, diagonal and forward
		tmp2.x		= (float) for_diag_mask * g_cos[2].x;
		tmp2.y		= (float) for_diag_mask * g_cos[2].y;
		//tmp.x		= tmp2.x*tmp.x - tmp2.y*tmp.y;
		tmp3.x		= tmp2.x*tmp.x - tmp2.y*tmp.y;
		tmp.y		= tmp2.y*tmp.x + tmp2.x*tmp.y;
		tmp.x		= tmp3.x;
		//-ve sin on diagonal-1
		tmp.x		-= (float) sub_diag_mask * g_sin[2].x;
		tmp.y		+= (float) sub_diag_mask * g_sin[2].y;

		//write
		q_temp[ global_row ] = tmp;

		//work up columns of matrix		
		for (int j=3; j<=steps; j++){

			tmp.x		= 0.0f;
			tmp.y		= 0.0f;
			i		= MATRIX_SIDE-1-j;

			// last row element
			tmp.x 		= (float) last_col_mask * g_sin[0].x;
			tmp.y 		= (float) last_col_mask * g_sin[0].y;

			// prior row elements
			tmp.x 		+= (float) ( for_diag_mask  && !last_col_mask ) * g_cos [ cosIndex ].x;
			tmp.y 		+= (float) ( for_diag_mask  && !last_col_mask ) * g_cos [ cosIndex ].y;


			// multiply in the sin terms
			tmp2.x	= (float) above_diag_mask * g_sin[j-1].x;
			tmp2.x	+= (float) !(above_diag_mask);
			tmp2.y	= (float) above_diag_mask * g_sin[j-1].y;

			tmp3.x	= mult.x*tmp2.x - mult.y*tmp2.y;
			mult.y	= mult.y*tmp2.x + mult.x*tmp2.y;
			mult.x	= tmp3.x;

			// check if nan first
			mult.x	= (isnan(mult.x)) ? 0 : mult.x;
			mult.y	= (isnan(mult.y)) ? 0 : mult.y;
			tmp3.x	= tmp.x*mult.x - tmp.y*mult.y;
			tmp.y	= tmp.y*mult.x + tmp.x*mult.y;
			tmp.x	= tmp3.x;


			// final cos & sin terms
			tmp2.x	= (float) for_diag_mask * g_cos[j].x;
			tmp2.x	+= (float) !(for_diag_mask);
			tmp2.y	= (float) for_diag_mask * g_cos[j].y;

			tmp3.x	= tmp.x*tmp2.x - tmp.y*tmp2.y;
			tmp.y	= tmp.y*tmp2.x + tmp.x*tmp2.y;
			tmp.x	= tmp3.x;

			tmp.x	-= (float) sub_diag_mask * g_sin[j].x;
			tmp.y	+= (float) sub_diag_mask * g_sin[j].y;

			// write
			q_temp[ global_row ] = tmp;
		}

		if (steps < MATRIX_SIDE-1){

			for (int i=0; i<MATRIX_SIDE-steps-1; i++){

				tmp.x		= (float) diag_mask;
				tmp.y		= 0.0;
				q_temp[ global_row ] = tmp;
			} 

		}
	} else{ 
		q_temp[ global_row ] = tmp;



		for (int i=MATRIX_SIDE-3; i>=0; i--){
			tmp.x		= (float) diag_mask;
			tmp.y		= 0.0;
			q_temp[ global_row ] = tmp;
		}
	}

}


extern "C"{

	void givens_qr_bat(float * mats, int size, float * q){

		float2 *q_temp,*q_tempB,*q_complete,*matrices;

		// Array of pointers to matrix locations
		float2 **q_cblas_tempA,**q_cblas_tempB, **q_cblas_complete;


		//initialize q
		for (int k=0; k<size; k++)
			for (int i=0; i<MATRIX_SIDE; i++)		
				for (int j=0; j<2*MATRIX_SIDE; j++)
					q[j+i*2*MATRIX_SIDE+k*MATRIX_SIDE*MATRIX_SIDE*2] = (2*i==j) ? 1.0 :0.0;		

		int qsize = size*MATRIX_SIDE*MATRIX_SIDE;

		cudaMemcpyToSymbol(cmem_size,&size,sizeof(size));
		cudaMemcpyToSymbol(cmem_size_MM,&qsize,sizeof(qsize));

		// Allocate memory and copy data
		cudaMalloc((void**) &q_complete, sizeof(float2)*size*MATRIX_SIDE*MATRIX_SIDE);
		cudaMemcpy(q_complete, q, sizeof(float2)*MATRIX_SIDE*MATRIX_SIDE*size, cudaMemcpyHostToDevice);

		cudaMalloc((void**) &q_temp, sizeof(float2)*size*MATRIX_SIDE*MATRIX_SIDE);
		cudaMalloc((void**) &q_tempB, sizeof(float2)*size*MATRIX_SIDE*MATRIX_SIDE);

		cudaMalloc((void**) &matrices, sizeof(float2)*size*MATRIX_SIDE*MATRIX_SIDE);
		cudaMemcpy(matrices, mats, sizeof(float2)*MATRIX_SIDE*MATRIX_SIDE*size, cudaMemcpyHostToDevice);

		// Allocate the arrays of pointers
		cudaMalloc((void**)&q_cblas_tempA, sizeof(float2*)*size);
		cudaMalloc((void**)&q_cblas_tempB,sizeof(float2*)*size);
		cudaMalloc((void**)&q_cblas_complete,sizeof(float2*)*size);

		// Create the array of pointers
		create_ptr <<< (int)ceil((float)size/(float)NTH) , NTH >>> ( q_cblas_tempA, q_cblas_tempB, q_cblas_complete,q_temp,q_tempB,q_complete);

		cublasStatus_t status;
		cublasHandle_t handle;
		
		status = cublasCreate(&handle);
		if(status != CUBLAS_STATUS_SUCCESS) {
			fprintf(stderr,"ERROR: CUBLAS Initialization error\n");
			exit(0);
		}	
		cuComplex c_one = {1.0,0.0};
		cuComplex c_zro = {0.0,0.0};

		int nrows = MATRIX_SIDE;
		int ncol = MATRIX_SIDE;


		dim3 threads,blocks;

		threads.x 	= MATRIX_SIDE;
		blocks.x	= size;
		double begin = omp_get_wtime();	


		int dim1d_copy2tmp = (int)ceil(sqrt((float)size*(float)MATRIX_SIDE*(float)MATRIX_SIDE/(float)NTH));
		dim3 grid_copy2tmp;
		grid_copy2tmp.x = dim1d_copy2tmp;
		grid_copy2tmp.y = dim1d_copy2tmp;

		for (int i=0; i<MATRIX_SIDE-1; i++){

			qr_gpu_bat<<<blocks,threads>>>(i, matrices, q_temp, q_complete);
			#ifdef GPU_DEBUG
			checkCUDAError("QR_GPU_BAT FAILED",__FILE__,__LINE__-1);
			#endif
			
			// Copy content of q_complete to q_tempB for batch GEMM
			copy_to_temp <<< grid_copy2tmp , NTH >>> (q_tempB,q_complete);
			#ifdef GPU_DEBUG
			checkCUDAError("Copy to temp failed",__FILE__,__LINE__-1);
			#endif

				status = cublasCgemmBatched(	handle,
								CUBLAS_OP_N,CUBLAS_OP_N,
								MATRIX_SIDE,MATRIX_SIDE,MATRIX_SIDE,
								&c_one,
								(const cuComplex**)q_cblas_tempB,nrows,
								(const cuComplex**)q_cblas_tempA,ncol,
								&c_zro,
								(cuComplex**)q_cblas_complete,nrows,
								size);
				if(status != CUBLAS_STATUS_SUCCESS) {
					fprintf(stderr,"ERROR: CUBLAS CGEMM BATCHED error = %d\n",status);
					exit(0);
				}	

		}//end main loops



	#ifdef _QR_VERBOSE_

		float2 * q_dump = (float2 *) malloc(sizeof(float2)*size*MATRIX_SIDE*MATRIX_SIDE);
		cudaMemcpy(q_dump, q_complete, sizeof(float2)*MATRIX_SIDE*MATRIX_SIDE*size, cudaMemcpyDeviceToHost);
		float2 * r_dump = (float2 *) malloc(sizeof(float2)*size*MATRIX_SIDE*MATRIX_SIDE);
		cudaMemcpy(r_dump, matrices, sizeof(float2)*MATRIX_SIDE*MATRIX_SIDE*size, cudaMemcpyDeviceToHost);


		// Take the transpose of q_complete is CUBLAS
		for (int k=0; k<size; k++){
			printf("q %i\n",k);
			for (int j=0; j<MATRIX_SIDE; j++) {
				for (int i=0; i<MATRIX_SIDE; i++){
					printf("%f+%fi, ",q_dump[j+MATRIX_SIDE*i+k*MATRIX_SIDE*MATRIX_SIDE].x,
							q_dump[j+MATRIX_SIDE*i+k*MATRIX_SIDE*MATRIX_SIDE].y);
			
				}	
					printf(";\n");
			}	

		}


		for (int k=0; k<size; k++){
			printf("r_mat %i\n",k);
			for (int i=0; i<MATRIX_SIDE; i++){
				for (int j=0; j<MATRIX_SIDE; j++)
					printf("%f+%fi, ",r_dump[j+MATRIX_SIDE*i+k*MATRIX_SIDE*MATRIX_SIDE].x,
							r_dump[j+MATRIX_SIDE*i+k*MATRIX_SIDE*MATRIX_SIDE].y);


				printf(";\n",i);
			}

		}


		free(r_dump);
		free(q_dump);

	#endif

		cudaDeviceSynchronize();
		double end = omp_get_wtime();
		printf("QR orig\t %f\n",end-begin);

		status = cublasDestroy(handle);

		cudaFree(q_temp);
		cudaFree(q_tempB);
		cudaFree(q_complete);
		cudaFree(matrices);
		cudaFree(q_cblas_tempA);
		cudaFree(q_cblas_tempB);
		cudaFree(q_cblas_complete);
	}
}


