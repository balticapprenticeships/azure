import json
import os
import redis
from azure.identity import DefaultAzureCredential
from azure.mgmt.compute import ComputeManagementClient

REDIS_HOST = os.environ["REDIS_HOST"]

r = redis.Redis(host=REDIS_HOST, port=6379, decode_responses=True)

def main(event: dict):

    event_type = event.get("eventType")

    vm_name = event["data"]["resourceUri"].split("/")[-1]

    # Example: resolve VM IP (simplified)
    private_ip = get_vm_ip(vm_name)

    dns_name = f"{vm_name}.balticlabs.co.uk"

    if event_type == "Microsoft.Resources.ResourceWriteSuccess":

        # Add mapping
        r.hset("rdp_backends", dns_name, private_ip)

    elif event_type == "Microsoft.Resources.ResourceDeleteSuccess":

        # Remove mapping
        r.hdel("rdp_backends", dns_name)

def get_vm_ip(vm_name):
    # Replace with real Azure SDK lookup
    return "10.1.1.5"