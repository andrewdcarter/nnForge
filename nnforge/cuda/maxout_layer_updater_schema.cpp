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

#include "maxout_layer_updater_schema.h"

#include "../neural_network_exception.h"
#include "../maxout_layer.h"
#include "maxout_layer_updater_cuda.h"

#include <boost/format.hpp>

namespace nnforge
{
	namespace cuda
	{
		maxout_layer_updater_schema::maxout_layer_updater_schema()
		{
		}

		maxout_layer_updater_schema::~maxout_layer_updater_schema()
		{
		}

		std::tr1::shared_ptr<layer_updater_schema> maxout_layer_updater_schema::create_specific() const
		{
			return layer_updater_schema_smart_ptr(new maxout_layer_updater_schema());
		}

		const boost::uuids::uuid& maxout_layer_updater_schema::get_uuid() const
		{
			return maxout_layer::layer_guid;
		}

		layer_updater_cuda_smart_ptr maxout_layer_updater_schema::create_updater_specific(
			const layer_configuration_specific& hyperbolic_tangent_layer_hessian_schema,
			const layer_configuration_specific& output_configuration_specific) const
		{
			return layer_updater_cuda_smart_ptr(new maxout_layer_updater_cuda());
		}
	}
}
