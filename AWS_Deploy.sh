#!/bin/bash

NETWORK=Goerli
#GethResTag="ResourceType=instance,Tags=[{Key=Name,Value=DevETH2.0_Geth_${NETWORK}}]"
#LighthouseResTag="ResourceType=instance,Tags=[{Key=Name,Value=DevETH2.0_Lighthouse_${NETWORK}}]"

ResTagArr=("ResourceType=instance,Tags=[{Key=Name,Value=TestETH2.0_Geth_${NETWORK}}]" "ResourceType=instance,Tags=[{Key=Name,Value=TestETH2.0_Lighthouse_${NETWORK}}]")

sudo yum update -y

#Install AWS Cli
if ! command -v aws &> /dev/null
then
    cd $HOME && curl "https://awscli.amazonaws.com/awscli-exe-linux-${uname -m}.zip" -o "awscliv2.zip" && unzip awscliv2.zip && sudo ./aws/install
    rm -r awscliv2 && rm awscliv2.zip
fi

EC2_Info=$(aws ec2 describe-instances --no-cli-page --query 'Reservations[*].Instances[?contains(PrivateDnsName,`ip-172-31-26-83.ec2.internal`)] | [0][0].{InstanceType: InstanceType, InstanceId: InstanceId, ImageId: ImageId, KeyName: KeyName, AvailabilityZone: Placement. AvailabilityZone, VpcId: VpcId, SubnetId: SubnetId, GroupId: NetworkInterfaces[0].Groups[0].GroupId}')

for tagValue in ${ResTagArr[@]}
do
    EC2Result=$(aws ec2 run-instances --no-cli-page --image-id $(echo $EC2_Info | jq -r '.ImageId') --count 1 --instance-type $(echo $EC2_Info | jq -r '.InstanceType') --key-name $(echo $EC2_Info | jq -r '.KeyName') --security-group-ids $(echo $EC2_Info | jq -r '.GroupId') --subnet-id $(echo $EC2_Info | jq -r '.SubnetId') --associate-public-ip-address --block-device-mappings file://ebs_mapping.json --tag-specifications $tagValue)
    echo $EC2Result
done

