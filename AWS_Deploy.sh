#!/bin/bash

NETWORK=Goerli

#"ResourceType=instance,Tags=[{Key=Name,Value=TestETH2.0_Lighthouse_${NETWORK}}]"
ResTagArr=("ResourceType=instance,Tags=[{Key=Name,Value=TestETH2.0_Geth_${NETWORK}}]")

sudo yum update -y
sudo yum install -y jq

#Install AWS Cli
if ! command -v aws &> /dev/null
then
    #aws-cli/2.7.31 Python/3.9.11 Linux/5.10.130-118.517.amzn2.aarch64 exe/aarch64.amzn.2 prompt/off
    if [ $(which aws) = "/usr/bin/aws" ]; then
        cd $HOME && curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip" && unzip awscliv2.zip && sudo ./aws/install
        rm -r aws && rm awscliv2.zip
    fi
fi

EC2_Info=$(aws ec2 describe-instances --no-cli-page --query 'Reservations[*].Instances[?contains(PrivateDnsName,`ip-172-31-26-83.ec2.internal`)] | [0][0].{InstanceType: InstanceType, InstanceId: InstanceId, ImageId: ImageId, KeyName: KeyName, AvailabilityZone: Placement. AvailabilityZone, VpcId: VpcId, SubnetId: SubnetId, GroupId: NetworkInterfaces[0].Groups[0].GroupId}')

for tagValue in ${ResTagArr[@]}
do
    EC2Result=$(aws ec2 run-instances --no-cli-page --image-id $(echo $EC2_Info | jq -r '.ImageId') --count 1 --instance-type $(echo $EC2_Info | jq -r '.InstanceType') --key-name $(echo $EC2_Info | jq -r '.KeyName') --security-group-ids $(echo $EC2_Info | jq -r '.GroupId') --subnet-id $(echo $EC2_Info | jq -r '.SubnetId') --associate-public-ip-address --block-device-mappings file://ebs_mapping.json --tag-specifications $tagValue)
    echo $EC2Result
done

