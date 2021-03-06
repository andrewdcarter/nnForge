/*
 *  Copyright 2011-2013 Maxim Milakov
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

#include "fully_connected_layer_hessian_cuda.h"

#include <cuda_runtime.h>

#include "util_cuda.h"
#include "neural_network_cublas_exception.h"
#include "../convolution_layer.h"

__global__ void copy_bias_hess_kernel(
	const float * __restrict biases,
	float * __restrict output,
	int output_neuron_count,
	int entry_count)
{
	int output_neuron_id = blockIdx.x * blockDim.x + threadIdx.x;
	int entry_id = (blockIdx.y * blockDim.y + threadIdx.y) * 4;

	if ((output_neuron_id < output_neuron_count))
	{
		float bias = biases[output_neuron_id];
		float * current_output = output + (int)(entry_id * output_neuron_count + output_neuron_id);
		#pragma unroll
		for(int i = 0; i < 4; ++i)
		{
			if (entry_id < entry_count)
				*current_output = bias;
			current_output += output_neuron_count;
			entry_id++;
		}
	}
}

__global__ void fully_connected_update_biases_hess_kernel(
	float * __restrict hessian_biases,
	const float * __restrict output_errors,
	int block_size,
	int output_elem_count_per_entry,
	int entry_count)
{
	int output_neuron_id = blockIdx.x * blockDim.x + threadIdx.x;
	int block_id = blockIdx.y * blockDim.y + threadIdx.y;
	int base_entry_id = block_size * block_id;
	int iteration_count = min(entry_count - base_entry_id, block_size);
	const float * current_error = output_errors + (base_entry_id * output_elem_count_per_entry + output_neuron_id);
	float sum = 0.0F;
	for(int i = 0; i < iteration_count; ++i)
	{
		sum += *current_error;
		current_error += output_elem_count_per_entry;
	}
	atomicAdd(hessian_biases + output_neuron_id, sum);
}

namespace nnforge
{
	namespace cuda
	{
		fully_connected_layer_hessian_cuda::fully_connected_layer_hessian_cuda()
		{
		}

		fully_connected_layer_hessian_cuda::~fully_connected_layer_hessian_cuda()
		{
		}

		void fully_connected_layer_hessian_cuda::enqueue_test(
			cudaStream_t stream_id,
			const std::vector<const_cuda_linear_buffer_device_smart_ptr>& schema_data,
			const std::vector<const_cuda_linear_buffer_device_smart_ptr>& data,
			const_cuda_linear_buffer_device_smart_ptr input_neurons_buffer,
			cuda_linear_buffer_device_smart_ptr output_neurons_buffer,
			const std::vector<cuda_linear_buffer_device_smart_ptr>& additional_buffers,
			unsigned int entry_count)
		{
			std::pair<dim3, dim3> kernel_dims = cuda_util::get_grid_and_threadblock_sizes_sequential_access(
				*cuda_config,
				output_elem_count_per_entry,
				(entry_count + 4 - 1) / 4,
				1);
			copy_bias_hess_kernel<<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(
				*data[1],
				*output_neurons_buffer,
				output_elem_count_per_entry,
				entry_count);

			cublas_safe_call(cublasSetStream(cuda_config->get_cublas_handle(), stream_id));
			float alpha = 1.0F;
			float beta = 1.0F;
			cublas_safe_call(cublasSgemm(
				cuda_config->get_cublas_handle(),
				CUBLAS_OP_T,
				CUBLAS_OP_N,
				output_elem_count_per_entry,
				entry_count,
				input_elem_count_per_entry,
				&alpha,
				*data[0],
				input_elem_count_per_entry,
				*input_neurons_buffer,
				input_elem_count_per_entry,
				&beta,
				*output_neurons_buffer,
				output_elem_count_per_entry));
		}

		void fully_connected_layer_hessian_cuda::enqueue_backprop(
			cudaStream_t stream_id,
			const std::vector<const_cuda_linear_buffer_device_smart_ptr>& schema_data,
			const std::vector<const_cuda_linear_buffer_device_smart_ptr>& data_squared,
			const_cuda_linear_buffer_device_smart_ptr output_neurons_buffer,
			cuda_linear_buffer_device_smart_ptr output_errors_buffer,
			cuda_linear_buffer_device_smart_ptr input_errors_buffer,
			const std::vector<cuda_linear_buffer_device_smart_ptr>& additional_buffers,
			unsigned int entry_count)
		{
			cublas_safe_call(cublasSetStream(cuda_config->get_cublas_handle(), stream_id));
			float alpha = 1.0F;
			float beta = 0.0F;
			cublas_safe_call(cublasSgemm(
				cuda_config->get_cublas_handle(),
				CUBLAS_OP_N,
				CUBLAS_OP_N,
				input_elem_count_per_entry,
				entry_count,
				output_elem_count_per_entry,
				&alpha,
				*data_squared[0],
				input_elem_count_per_entry,
				*output_errors_buffer,
				output_elem_count_per_entry,
				&beta,
				*input_errors_buffer,
				input_elem_count_per_entry));
		}

		void fully_connected_layer_hessian_cuda::enqueue_update_hessian(
			cudaStream_t stream_id,
			const std::vector<const_cuda_linear_buffer_device_smart_ptr>& schema_data,
			const std::vector<cuda_linear_buffer_device_smart_ptr>& hessian_data,
			cuda_linear_buffer_device_smart_ptr output_errors_buffer,
			const_cuda_linear_buffer_device_smart_ptr input_neurons_buffer,
			const std::vector<cuda_linear_buffer_device_smart_ptr>& additional_buffers,
			unsigned int entry_count)
		{
			// Update weights
			{
				// Store input neurons multiplied element-wise by themselves
				cuda_util::multiply_by_itself(
					*cuda_config,
					*input_neurons_buffer,
					*additional_buffers[0],
					input_elem_count_per_entry * entry_count,
					stream_id);

				cublas_safe_call(cublasSetStream(cuda_config->get_cublas_handle(), stream_id));
				float alpha = 1.0F;
				float beta = 1.0F;
				cublas_safe_call(cublasSgemm(
					cuda_config->get_cublas_handle(),
					CUBLAS_OP_N,
					CUBLAS_OP_T,
					input_elem_count_per_entry,
					output_elem_count_per_entry,
					entry_count,
					&alpha,
					*additional_buffers[0],
					input_elem_count_per_entry,
					*output_errors_buffer,
					output_elem_count_per_entry,
					&beta,
					*hessian_data[0],
					input_elem_count_per_entry));
			}

			// Update biases
			{
				int block_size = get_block_size(entry_count);
				int block_count = (entry_count + block_size - 1) / block_size;
				std::pair<dim3, dim3> kernel_dims = cuda_util::get_grid_and_threadblock_sizes_sequential_access(
					*cuda_config,
					output_elem_count_per_entry,
					block_count,
					1);
				fully_connected_update_biases_hess_kernel<<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(
					*hessian_data[1],
					*output_errors_buffer,
					block_size,
					output_elem_count_per_entry,
					entry_count);
			}
		}

		bool fully_connected_layer_hessian_cuda::is_in_place_backprop() const
		{
			return false;
		}

		std::vector<size_t> fully_connected_layer_hessian_cuda::get_sizes_of_additional_buffers_per_entry() const
		{
			std::vector<size_t> res;

			res.push_back(input_elem_count_per_entry * sizeof(float));

			return res;
		}

		int fully_connected_layer_hessian_cuda::get_block_size(int entry_count)
		{
			int block_size = std::min<int>(std::max<int>(static_cast<int>(sqrtf(static_cast<float>(entry_count))), 1), entry_count);
			return block_size;
		}
	}
}
