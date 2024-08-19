#!/bin/bash

export AWS_REGION=us-east-1
export CLUSTER_NAME=wsc2024-eks-cluster

CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER_NAME --output json| jq -r '.cluster.resourcesVpcConfig.clusterSecurityGroupId')

PREFIX_LIST_ID=$(aws ec2 describe-managed-prefix-lists --query "PrefixLists[?PrefixListName=="\'com.amazonaws.$AWS_REGION.vpc-lattice\'"].PrefixListId" | jq -r '.[]')
aws ec2 authorize-security-group-ingress --group-id $CLUSTER_SG --ip-permissions "PrefixListIds=[{PrefixListId=${PREFIX_LIST_ID}}],IpProtocol=-1"
PREFIX_LIST_ID_IPV6=$(aws ec2 describe-managed-prefix-lists --query "PrefixLists[?PrefixListName=="\'com.amazonaws.$AWS_REGION.ipv6.vpc-lattice\'"].PrefixListId" | jq -r '.[]')
aws ec2 authorize-security-group-ingress --group-id $CLUSTER_SG --ip-permissions "PrefixListIds=[{PrefixListId=${PREFIX_LIST_ID_IPV6}}],IpProtocol=-1"

curl https://raw.githubusercontent.com/aws/aws-application-networking-k8s/main/files/controller-installation/recommended-inline-policy.json  -o recommended-inline-policy.json
aws iam create-policy \
    --policy-name VPCLatticeControllerIAMPolicy \
    --policy-document file://recommended-inline-policy.json
export VPCLatticeControllerIAMPolicyArn=$(aws iam list-policies --query 'Policies[?PolicyName==`VPCLatticeControllerIAMPolicy`].Arn' --output text)

aws eks create-addon --cluster-name $CLUSTER_NAME --addon-name eks-pod-identity-agent --addon-version v1.0.0-eksbuild.1
kubectl get pods -n kube-system | grep 'eks-pod-identity-agent'

cat >gateway-api-controller-service-account.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
    name: gateway-api-controller
    namespace: aws-application-networking-system
EOF
kubectl apply -f gateway-api-controller-service-account.yaml

cat >trust-relationship.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowEksAuthToAssumeRoleForPodIdentity",
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
EOF

aws iam create-role --role-name VPCLatticeControllerIAMRole --assume-role-policy-document file://trust-relationship.json --description "IAM Role for AWS Gateway API Controller for VPC Lattice"
aws iam attach-role-policy --role-name VPCLatticeControllerIAMRole --policy-arn=$VPCLatticeControllerIAMPolicyArn
export VPCLatticeControllerIAMRoleArn=$(aws iam list-roles --query 'Roles[?RoleName==`VPCLatticeControllerIAMRole`].Arn' --output text)

aws eks create-pod-identity-association --cluster-name $CLUSTER_NAME --role-arn $VPCLatticeControllerIAMRoleArn --namespace aws-application-networking-system --service-account gateway-api-controller

aws ecr-public get-login-password --region us-east-1 | helm registry login --username AWS --password-stdin public.ecr.aws
helm install gateway-api-controller \
oci://public.ecr.aws/aws-application-networking-k8s/aws-gateway-controller-chart \
--version=v1.0.5 \
--namespace aws-application-networking-system \
--set=defaultServiceNetwork=wsc2024-lattice-svc-net \
--set=serviceAccount.create=false

