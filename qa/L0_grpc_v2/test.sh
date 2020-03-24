#!/bin/bash
# Copyright (c) 2019-2020, NVIDIA CORPORATION. All rights reserved.
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

REPO_VERSION=${NVIDIA_TENSORRT_SERVER_VERSION}
if [ "$#" -ge 1 ]; then
    REPO_VERSION=$1
fi
if [ -z "$REPO_VERSION" ]; then
    echo -e "Repository version must be specified"
    echo -e "\n***\n*** Test Failed\n***"
    exit 1
fi

export CUDA_VISIBLE_DEVICES=0

set +e

RET=0

SIMPLE_HEALTH_CLIENT=../clients/simple_grpc_v2_health_metadata.py
SIMPLE_INFER_CLIENT=../clients/simple_grpc_v2_infer_client.py
SIMPLE_ASYNC_INFER_CLIENT=../clients/simple_grpc_v2_async_infer_client.py
SIMPLE_STRING_INFER_CLIENT=../clients/simple_grpc_v2_string_infer_client.py
SIMPLE_SEQUENCE_INFER_CLIENT=../clients/simple_grpc_v2_sequence_infer_client.py
SIMPLE_CLASS_CLIENT=../clients/simple_grpc_v2_class_client.py
SIMPLE_SHM_CLIENT=../clients/simple_grpc_v2_shm_client.py
SIMPLE_CUDASHM_CLIENT=../clients/simple_grpc_v2_cudashm_client.py
SIMPLE_MODEL_CONTROL=../clients/simple_grpc_v2_model_control.py
EXPLICIT_BYTE_CONTENT_CLIENT=../clients/grpc_v2_explicit_byte_content_client.py
EXPLICIT_INT_CONTENT_CLIENT=../clients/grpc_v2_explicit_int_content_client.py
EXPLICIT_INT8_CONTENT_CLIENT=../clients/grpc_v2_explicit_int8_content_client.py
GRPC_V2_CLIENT=../clients/grpc_v2_client.py
GRPC_IMAGE_CLIENT=../clients/grpc_v2_image_client.py

rm -f *.log
rm -f *.log.*

# Get the TensorFlow inception model
mkdir -p models/inception_graphdef/1
wget -O /tmp/inception_v3_2016_08_28_frozen.pb.tar.gz \
     https://storage.googleapis.com/download.tensorflow.org/models/inception_v3_2016_08_28_frozen.pb.tar.gz
(cd /tmp && tar xzf inception_v3_2016_08_28_frozen.pb.tar.gz)
mv /tmp/inception_v3_2016_08_28_frozen.pb models/inception_graphdef/1/model.graphdef
cp -r /data/inferenceserver/${REPO_VERSION}/qa_model_repository/graphdef_int8_int32_int32 models/
cp -r /data/inferenceserver/${REPO_VERSION}/tf_model_store/resnet_v1_50_graphdef models/

CLIENT_LOG=`pwd`/client.log
DATADIR=`pwd`/models
SERVER=/opt/tensorrtserver/bin/trtserver
SERVER_ARGS="--model-repository=$DATADIR --api-version 2"
source ../common/util.sh

# FIXMEPV2
# Cannot use run_server since it repeatedly curls the (old) HTTP health endpoint to know
# when the server is ready. This endpoint would not exist in future.
run_server_nowait
sleep 10
if [ "$SERVER_PID" == "0" ]; then
    echo -e "\n***\n*** Failed to start $SERVER\n***"
    cat $SERVER_LOG
    exit 1
fi

# Test health
python $SIMPLE_HEALTH_CLIENT -v >> ${CLIENT_LOG}.health 2>&1
if [ $? -ne 0 ]; then
    cat ${CLIENT_LOG}.health
    RET=1
fi

if [ $(cat ${CLIENT_LOG}.health | grep "PASS" | wc -l) -ne 7 ]; then
    cat ${CLIENT_LOG}.health
    RET=1
fi

IMAGE=../images/vulture.jpeg
for i in \
        $SIMPLE_INFER_CLIENT \
        $SIMPLE_ASYNC_INFER_CLIENT \
        $SIMPLE_STRING_INFER_CLIENT \
        $SIMPLE_CLASS_CLIENT \
        $SIMPLE_SEQUENCE_INFER_CLIENT \
        $SIMPLE_SHM_CLIENT \
        $SIMPLE_CUDASHM_CLIENT \
        $EXPLICIT_BYTE_CONTENT_CLIENT \
        $EXPLICIT_INT_CONTENT_CLIENT \
        $EXPLICIT_INT8_CONTENT_CLIENT \
        $GRPC_V2_CLIENT \
        $GRPC_IMAGE_CLIENT \
        ; do
    BASE=$(basename -- $i)
    SUFFIX="${BASE%.*}"
    if [[ $SUFFIX == "simple_grpc_v2_class_client" || $SUFFIX == "grpc_v2_image_client" ]]; then
        python $i -m inception_graphdef -s INCEPTION -c 1 -b 1 $IMAGE >> "${CLIENT_LOG}.${SUFFIX}" 2>&1
    else
        python $i -v >> "${CLIENT_LOG}.${SUFFIX}" 2>&1
    fi

    if [ $? -ne 0 ]; then
        cat "${CLIENT_LOG}.${SUFFIX}"
        RET=1
    fi

    if [ $(cat "${CLIENT_LOG}.${SUFFIX}" | grep "PASS" | wc -l) -ne 1 ]; then
        cat "${CLIENT_LOG}.${SUFFIX}"
        RET=1
    fi
done

kill $SERVER_PID
wait $SERVER_PID

SERVER_ARGS="--model-repository=$DATADIR --model-control-mode=explicit --api-version 2"
# FIXMEPV2
# Cannot use run_server since it repeatedly curls the (old) HTTP health endpoint to know
# when the server is ready. This endpoint would not exist in future.
run_server_nowait
sleep 10
if [ "$SERVER_PID" == "0" ]; then
    echo -e "\n***\n*** Failed to start $SERVER\n***"
    cat $SERVER_LOG
    exit 1
fi

# Test Model Control API
python $SIMPLE_MODEL_CONTROL -v >> ${CLIENT_LOG}.model_control 2>&1
if [ $? -ne 0 ]; then
    cat ${CLIENT_LOG}.model_control
    RET=1
fi

if [ $(cat ${CLIENT_LOG}.model_control | grep "PASS" | wc -l) -ne 1 ]; then
    cat ${CLIENT_LOG}.model_control
    RET=1
fi

kill $SERVER_PID
wait $SERVER_PID

set -e


if [ $RET -eq 0 ]; then
    echo -e "\n***\n*** Test Passed\n***"
else
    echo -e "\n***\n*** Test FAILED\n***"
fi

exit $RET
