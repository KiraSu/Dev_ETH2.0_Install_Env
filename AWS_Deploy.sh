#!/bin/bash

ARCHI=$(uname -m)
NETWORK=goerli
RUN_DIR=$(pwd)
LIGHTHOUSE_CONFIG_JSON=
BEACON_NODE_CHECKPOINT_URL="https://goerli.checkpoint-sync.ethdevops.io"
ResTagArr=("ResourceType=instance,Tags=[{Key=Name,Value=TestETH_geth_${NETWORK}}]" "ResourceType=instance,Tags=[{Key=Name,Value=TestETH_lighthouse_${NETWORK}}]")
EBS_JSON="[\
    {\
        \"DeviceName\": \"/dev/xvda\",\
        \"Ebs\": {\
            \"VolumeType\": \"gp3\",\
            \"VolumeSize\": 64\
        }\
    },\
    {\
	\"DeviceName\": \"/dev/sdf\",\
        \"Ebs\": {\
            \"VolumeType\": \"gp3\",\
            \"VolumeSize\": 256\
        }\
    }\
]"

sudo yum update -y

if ! command -v jq &> /dev/null
then
    sudo yum install -y jq
fi

#Install AWS Cli
if command -v aws &> /dev/null
then
    #aws-cli/2.7.31 Python/3.9.11 Linux/5.10.130-118.517.amzn2.aarch64 exe/aarch64.amzn.2 prompt/off
    if [ $(which aws) = "/usr/bin/aws" ]; then
	echo "Upgrade AWS Cli..."
        cd $HOME && curl "https://awscli.amazonaws.com/awscli-exe-linux-$ARCHI.zip" -o "awscliv2.zip" && unzip awscliv2.zip && sudo ./aws/install
        rm -r aws && rm awscliv2.zip
    fi
else
    echo "Install AWS Cli...."
    cd $HOME && curl "https://awscli.amazonaws.com/awscli-exe-linux-$ARCHI.zip" -o "awscliv2.zip" && unzip awscliv2.zip && sudo ./aws/install
    rm -r aws && rm awscliv2.zip
fi

EC2_InfoCMD=$(echo "aws ec2 describe-instances --no-cli-page --query 'Reservations[*].Instances[?contains(InstanceId,\`$(curl http://169.254.169.254/latest/meta-data/instance-id)\`)]|[].{InstanceType:InstanceType,InstanceId:InstanceId,ImageId:ImageId,KeyName:KeyName,AvailabilityZone:Placement.AvailabilityZone,VpcId:VpcId,SubnetId:SubnetId,GroupId:NetworkInterfaces[0].Groups[0].GroupId}'")

echo $EC2_InfoCMD
EC2_Info=$(eval $EC2_InfoCMD)
echo "EC2_Info: ${EC2_Info}"

echo $EBS_JSON > $RUN_DIR/ebs_mapping.json

for tagValue in ${ResTagArr[@]}
do
    EC2Result=$(aws ec2 run-instances --no-cli-page --image-id $(echo $EC2_Info | jq -r '.[0].ImageId') --count 1 --instance-type $(echo $EC2_Info | jq -r '.[0].InstanceType') --key-name $(echo $EC2_Info | jq -r '.[0].KeyName') --security-group-ids $(echo $EC2_Info | jq -r '.[0].GroupId') --subnet-id $(echo $EC2_Info | jq -r '.[0].SubnetId') --associate-public-ip-address --block-device-mappings file://$RUN_DIR/ebs_mapping.json --tag-specifications $tagValue)
    
    echo $EC2Result
    EC2InstanId=$(echo $EC2Result | jq -r '.Instances[0].InstanceId')
    EC2WaitStateRunning=$(aws ec2 wait instance-running --instance-ids $EC2InstanId)
    sleep 5s
    
    RemoteEC2Hostname=$(echo $EC2Result | jq -r '.Instances[0].Tags[0].Value')
    RemoteEC2IpAddr="$(echo $EC2Result | jq -r '.Instances[0].PrivateIpAddress')"
    RemoteSSHEC2Info="ec2-user@$RemoteEC2IpAddr"

    CMDModifyRemoteEC2HostName="ssh -i $RUN_DIR/key.pem $RemoteSSHEC2Info 'sudo hostnamectl --static set-hostname '$RemoteEC2Hostname''"
    echo "CMDModifyRemoteEC2HostName: $CMDModifyRemoteEC2HostName"
    eval $CMDModifyRemoteEC2HostName
    if [ $? -ne 0 ]; then
        sleep 5s
	eval $CMDModifyRemoteEC2HostName
	if [ $? -ne 0 ]; then
            echo "RemoteExecute[$CMDModifyRemoteEC2HostName] Failed. Try terminate this[$EC2InstanId] EC2 instance..."
	    aws ec2 terminate-instances --instance-ids $EC2InstanId
	    exit 0
	fi
    fi

    CMDCopyInstallScript="scp -i $RUN_DIR/key.pem ./Install.sh $RemoteSSHEC2Info:~"
    echo "CMDCopyInstallScript: $CMDCopyInstallScript"
    eval $CMDCopyInstallScript
    if [ $? -ne 0 ]; then
        echo "RemoteExecute[$CMDCopyInstallScript] Failed. Try terminate this[$EC2InstanId] EC2 instance..."
        aws ec2 terminate-instances --instance-ids $EC2InstanId
        exit 0
    fi
    
    ConfigData="{\"NETWORK\": \"$NETWORK\"}"
    CMDCopyInstallConfigJson="scp -i $RUN_DIR/key.pem ./config.json $RemoteSSHEC2Info:~"
    if [[ ! -z $LIGHTHOUSE_CONFIG_JSON ]]; then
        ConfigData=$LIGHTHOUSE_CONFIG_JSON
    fi
    echo "$ConfigData" > config.json
    echo "CMDCopyInstallConfigJson: $CMDCopyInstallConfigJson"
    eval $CMDCopyInstallConfigJson
    if [ $? -ne 0 ]; then
        echo "RemoteExecute[$CMDCopyInstallConfigJson] Failed. Try terminate this[$EC2InstanId] EC2 instance..."
        aws ec2 terminate-instances --instance-ids $EC2InstanId
        exit 0
    fi
    
    CMDExeScript="ssh -i $RUN_DIR/key.pem $RemoteSSHEC2Info '~/Install.sh'"
    echo $CMDExeScript
    eval $CMDExeScript
    if [ $? -ne 0 ]; then
        echo "RemoteExecute[$CMDExeScript] Failed. Try terminate this[$EC2InstanId] EC2 instance..."
        aws ec2 terminate-instances --instance-ids $EC2InstanId
        exit 0
    fi
    
    if [[ $RemoteEC2Hostname == *"geth"* ]]; then
	echo "Waiting $RemoteEC2Hostname service startup..."
	sleep 5s
	
	CMDGetJWTSecret="ssh -i $RUN_DIR/key.pem $RemoteSSHEC2Info 'sudo cat /var/lib/geth/.ethereum/goerli/geth/jwtsecret'"
	EXECUTION_JWTSECRET=$(eval $CMDGetJWTSecret)
	if [ $? -ne 0 ]; then
	    echo "Get[$CMDGetJWTSecret] EXECUTION_JWTSECRET failed."
	    exit 0
	fi
	LIGHTHOUSE_CONFIG_JSON="{\"NETWORK\": \"$NETWORK\", \"BEACON_NODE_CHECKPOINT_URL\": \"$BEACON_NODE_CHECKPOINT_URL\", \"EXECUTION_ENDPOINT\": \"$RemoteEC2IpAddr\", \"EXECUTION_JWTSECRET\": \"$EXECUTION_JWTSECRET\"}"
	echo "LIGHTHOUSE_CONFIG_JSON: $LIGHTHOUSE_CONFIG_JSON"
    fi
done

