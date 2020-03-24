#!/usr/bin/env python
# Copyright (c) 2020, NVIDIA CORPORATION. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#  * Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#  * Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#  * Neither the name of NVIDIA CORPORATION nor the names of its
#    contributors may be used to endorse or promote products derived
#    from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
# OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import argparse
import numpy as np
import os
from builtins import range
import tritongrpcclient.core as grpcclient
import tritongrpcclient.shared_memory as shm
from ctypes import *

FLAGS = None

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('-v',
                        '--verbose',
                        action="store_true",
                        required=False,
                        default=False,
                        help='Enable verbose output')
    parser.add_argument('-u',
                        '--url',
                        type=str,
                        required=False,
                        default='localhost:8001',
                        help='Inference server URL. Default is localhost:8001.')

    FLAGS = parser.parse_args()

    try:
        triton_client = grpcclient.InferenceServerClient(FLAGS.url)
    except Exception as e:
        print("channel creation failed: " + str(e))
        sys.exit()

    # To make sure no shared memory regions are registered with the
    # server.
    triton_client.unregister_system_shared_memory()
    triton_client.unregister_cuda_shared_memory()

    # We use a simple model that takes 2 input tensors of 16 integers
    # each and returns 2 output tensors of 16 integers each. One
    # output tensor is the element-wise sum of the inputs and one
    # output is the element-wise difference.
    model_name = "simple"
    model_version = ""

    # Create the data for the two input tensors. Initialize the first
    # to unique integers and the second to all ones.
    input0_data = np.arange(start=0, stop=16, dtype=np.int32)
    input1_data = np.ones(shape=16, dtype=np.int32)

    input_byte_size = input0_data.size * input0_data.itemsize
    output_byte_size = input_byte_size

    # Create Output0 and Output1 in Shared Memory and store shared memory handles
    shm_op0_handle = shm.create_shared_memory_region("output0_data",
                                                     "/output0_simple",
                                                     output_byte_size)
    shm_op1_handle = shm.create_shared_memory_region("output1_data",
                                                     "/output1_simple",
                                                     output_byte_size)

    # Register Output0 and Output1 shared memory with Triton Server
    triton_client.register_system_shared_memory("output0_data",
                                                "/output0_simple",
                                                output_byte_size)
    triton_client.register_system_shared_memory("output1_data",
                                                "/output1_simple",
                                                output_byte_size)

    # Create Input0 and Input1 in Shared Memory and store shared memory handles
    shm_ip0_handle = shm.create_shared_memory_region("input0_data",
                                                     "/input0_simple",
                                                     input_byte_size)
    shm_ip1_handle = shm.create_shared_memory_region("input1_data",
                                                     "/input1_simple",
                                                     input_byte_size)

    # Put input data values into shared memory
    shm.set_shared_memory_region(shm_ip0_handle, [input0_data])
    shm.set_shared_memory_region(shm_ip1_handle, [input1_data])

    # Register Input0 and Input1 shared memory with Triton Server
    triton_client.register_system_shared_memory("input0_data", "/input0_simple",
                                                input_byte_size)
    triton_client.register_system_shared_memory("input1_data", "/input1_simple",
                                                input_byte_size)

    # Set the parameters to use data from shared memory
    inputs = []
    inputs.append(grpcclient.InferInput('INPUT0', [1, 16], "INT32"))
    inputs[-1].set_parameter("shared_memory_region", "input0_data")
    inputs[-1].set_parameter("shared_memory_byte_size", input_byte_size)

    inputs.append(grpcclient.InferInput('INPUT1', [1, 16], "INT32"))
    inputs[-1].set_parameter("shared_memory_region", "input1_data")
    inputs[-1].set_parameter("shared_memory_byte_size", input_byte_size)

    outputs = []
    outputs.append(grpcclient.InferOutput('OUTPUT0'))
    # outputs[-1].set_parameter("shared_memory_region", "output0_data")
    # outputs[-1].set_parameter("shared_memory_byte_size", output_byte_size)

    outputs.append(grpcclient.InferOutput('OUTPUT1'))
    # outputs[-1].set_parameter("shared_memory_region", "output1_data")
    # outputs[-1].set_parameter("shared_memory_byte_size", output_byte_size)

    results = triton_client.infer(inputs=inputs,
                                  outputs=outputs,
                                  model_name=model_name)

    # TODO : Currently, this example doesn't use shared memory for output.
    # This is done to effectively validate the results.
    # tritongrpcclient.shared_memory module will be enhanced to read
    # data from a specified shared memory handle, data_type and shape;
    # and later return the numpy array.
    output0_data = results.as_numpy('OUTPUT0')
    output1_data = results.as_numpy('OUTPUT1')

    for i in range(16):
        print(str(input0_data[i]) + " + " + str(input1_data[i]) + " = " +
              str(output0_data[0][i]))
        print(str(input0_data[i]) + " - " + str(input1_data[i]) + " = " +
              str(output1_data[0][i]))
        if (input0_data[i] + input1_data[i]) != output0_data[0][i]:
            print("shm infer error: incorrect sum")
            sys.exit(1)
        if (input0_data[i] - input1_data[i]) != output1_data[0][i]:
            print("shm infer error: incorrect difference")
            sys.exit(1)

    print(triton_client.get_system_shared_memory_status())
    triton_client.unregister_system_shared_memory()
    shm.destroy_shared_memory_region(shm_ip0_handle)
    shm.destroy_shared_memory_region(shm_ip1_handle)
    shm.destroy_shared_memory_region(shm_op0_handle)
    shm.destroy_shared_memory_region(shm_op1_handle)

    print('PASS: shm')
