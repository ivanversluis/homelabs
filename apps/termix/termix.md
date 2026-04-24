# Termix Homelab wiki

## Documentation
https://termix.site/

## Repo
https://github.com/goauthentik/authentikhttps://github.com/Termix-SSH/Termix

## Releases
https://github.com/users/LukeGus/packages/container/package/termix

## Latest version


## Objective
As home-admin I want to easy and quickly connect to my devices. The devices are running SSH protocol and I want to do that from a web interface. 

## Implementation
To facilitate my objective I will be using a self hosted solution called Termix. Portainer will be used to deploy the stack which is pulled from Githun repo.

## Stack
To learn the Termix solution I will initially start with Docker Compose. 

## LLD
Network: VLAN200 for now until new VLAN is created for inband management

Volume: Create a volume to store /app/data where .env and db.sqlite.encrypted files

Port: tcp/3000


