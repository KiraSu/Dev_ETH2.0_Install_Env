#!/bin/bash

ARCHI=$(uname -m)
NETWORK=Goerli
ResTagArr=("ResourceType=instance,Tags=[{Key=Name,Value=TestETH2.0_Geth_${NETWORK}}]" "ResourceType=instance,Tags=[{Key=Name,Value=TestETH2.0_Lighthouse_${NETWORK}}]")

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

for tagValue in ${ResTagArr[@]}
do
    EC2Result=$(aws ec2 run-instances --no-cli-page --image-id $(echo $EC2_Info | jq -r '.[0].ImageId') --count 1 --instance-type $(echo $EC2_Info | jq -r '.[0].InstanceType') --key-name $(echo $EC2_Info | jq -r '.[0].KeyName') --security-group-ids $(echo $EC2_Info | jq -r '.[0].GroupId') --subnet-id $(echo $EC2_Info | jq -r '.[0].SubnetId') --associate-public-ip-address --block-device-mappings file://ebs_mapping.json --tag-specifications $tagValue)
    echo $EC2Result
done
