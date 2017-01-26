# web-application cluster boiler-plate
Documentation and copy-pasteable boilerplate for running a full web application in a micro-services style. Many pieces are optional and could be swapped out to match others desires.

## Assumptions and Opinions
* Alpine Linux is my prefered containerized OS, and the choice I've made for images
* CoreOS is the chosen host operating system
  * fleet comes for free for orchestration
  * etcd comes for free for a key value store

## Requirements and Features
* Dockerized nginx container to host static site
  * Forward's nginx logs to the docker service, [loggly logging strategy article](https://www.loggly.com/blog/top-5-docker-logging-methods-to-fit-your-container-deployment-strategy/)
  * Automatically reconfigures and refreshes nginx config based on routing configuration provided through etcd
  * SSL termination
  * By default forward http connections to https
  * Have a configuration mode which allows initial letsencrypt validation over http
  * Oauth & Oauth2 Termination
    * JWT generation and validation
* Https certificate from letsencrypt with autorenewal
* Static Front End boilerplate, with static component upgrade strategy
* Containerized Node.js server with application upgrade strategy
  * Boilerplate to publish to etcd
  * Discovers database from etcd
* Dockerized  RethinkDB
  * Boilerplate to publish to etcd

## Externalities
* Configure DNS
* Create machine instances
* Firewall
* Create fleet cluster
    * Tag instances
* Machine instance monitoring

## Frontend
### Basic Cloud Config
Just an example. Starts fleet, bootstraps a single static etcd cluster with only the single instance as both frontend and backend
The way I finally loaded it was using the command
sudo coreos-cloudinit --from-file=/home/chad_autry/cloud-config.yaml


```
#cloud-config

coreos:
  etcd2:
    name: etcdserver
    initial-cluster: etcdserver=http://10.142.0.2:2380
    initial-advertise-peer-urls: http://10.142.0.2:2380
    advertise-client-urls: http://10.142.0.2:2379
    listen-client-urls: http://0.0.0.0:2379
    listen-peer-urls: http://0.0.0.0:2380
  fleet:
      public-ip: 10.142.0.2
      metadata: "frontend=true",backend=true
  units:
    - name: etcd2.service
      command: start
    - name: fleet.service
      command: start
```
### nginx unit
The main unit for the front end, nginx is the static file server and reverse proxy. Can have redundant identical instances.

[nginx.service](units/nginx.service)
```yaml
[Unit]
Description=NGINX
# Dependencies
Requires=docker.service

# Ordering
After=docker.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-nginx
ExecStartPre=-/usr/bin/docker rm nginx
ExecStart=/usr/bin/docker run --name nginx -p 80:80 -p 443:443 \
-v /var/www:/usr/share/nginx/html:ro -v /var/ssl:/etc/nginx/ssl:ro \
-v /var/nginx:/usr/var/nginx:ro \
chadautry/wac-nginx
Restart=always

[X-Fleet]
Global=true
MachineMetadata=frontend=true
```
* requires docker
* wants all files to be copied before startup
* Starts a customized nginx docker container
    * Takes server config from local drive
    * Takes html from local drive
    * Takes certs from local drive
* Blindly runs on all frontend tagged instances

### nginx reloading units
A pair of units are responsible for reloading nginx instances on file changes

[nginx-reload.service](units/nginx-reload.service)
```yaml
[Unit]
Description=NGINX reload service

[Service]
ExecStart=-/usr/bin/docker kill -s HUP nginx
Type=oneshot

[X-Fleet]
Global=true
MachineMetadata=frontend=true
```
* Sends a signal to the named nginx container to reload
* Ignores errors
* It is a one shot which expects to be called by other units
* Metadata will cause it to be made available on all frontend servers when loaded

[nginx-reload.path](units/nginx-reload.path)
```yaml
[Unit]
Description=NGINX reload path

[Path]
PathChanged=/var/nginx/nginx.conf
PathChanged=/var/ssl/fullchain.pem

[X-Fleet]
Global=true
MachineMetadata=frontend=true
```
* Watches config file
* Watches the (last copied) SSL cert file
* Automatically calls nginx-reload.service on change (because of matching unit name)
* Blindly runs on all frontend tagged instances

### SSL
With nginx in place, several units are responsible for updating its SSL certificates

#### acme challenge response watcher
This unit takes the acme challenge response from etcd, and templates it into the nginx config

[acme-response-watcher.service](units/acme-response-watcher.service)
```yaml
[Unit]
Description=Watches for distributed acme challenge responses
# Dependencies
Requires=etcd2.service

# Ordering
After=etcd2.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-nginx-config-templater
ExecStartPre=-/usr/bin/docker rm nginx-templater
ExecStart=/usr/bin/etcdctl watch /acme/watched
ExecStartPost=-/usr/bin/docker run --name nginx-templater --net host \
-v /var/nginx:/usr/var/nginx -v /var/ssl:/etc/nginx/ssl:ro \
chadautry/wac-nginx-config-templater
Restart=always

[X-Fleet]
Global=true
MachineMetadata=frontend=true
```
* Starts a watch for changes in the acme challenge response
* Once the watch starts, executes the config templating container
    * Local volume mapped in for the templated config to be written to
    * Doesn't error out (TODO move to a secondary unit to be safely concurrent)
* If the watch is ever satisfied, the unit will exit
* Automatically restarted, causing a new watch and templater execution
* Blindly runs on all frontend tagged instances

#### SSL Certificate Syncronization
This unit takes the SSL certificates from etcd, and writes them to the local system

[certificate-sync.service](units/certificate-sync.service)
```yaml
[Unit]
Description=SSL Certificate Syncronization
# Dependencies
Requires=etcd2.service

# Ordering
After=etcd2.service

[Service]
ExecStartPre=-mkdir /var/ssl
ExecStart=/usr/bin/etcdctl watch /ssl/watched
ExecStartPost=/bin/sh -c '/usr/bin/etcdctl get /ssl/server_chain > /var/ssl/chain.pem'
ExecStartPost=/bin/sh -c '/usr/bin/etcdctl get /ssl/key > /var/ssl/privkey.pem'
ExecStartPost=/bin/sh -c '/usr/bin/etcdctl get /ssl/server_pem > /var/ssl/fullchain.pem'
Restart=always

[X-Fleet]
Global=true
MachineMetadata=frontend=true
```
* Starts a watch for SSL cert changes to copy
* Once the watch starts, copy the current certs
* If the watch is ever satisfied, the unit will exit
* Automatically restarted, causing a new watch and copy
* Metadata driven, don't bother with binding

#### letsencrypt renewal units
A pair of units are responsible for initiating the letsencrypt renewal process each month

[letsencrypt-renewal.service](units/letsencrypt-renewal.service)
```yaml
[Unit]
Description=Letsencrpyt renewal service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-acme
ExecStartPre=-/usr/bin/docker rm acme
ExecStart=-/usr/bin/docker run --net host --name acme chadautry/wac-acme
Type=oneshot

[X-Fleet]
Global=true
MachineMetadata=frontend=true
```
* Calls the wac-acme container to create/renew the cert
    * Container takes domain name and domain admin e-mail from etcd
    * Container interacts with other units/containers to manage the renewal process through etcd
* Ignores errors
* It is a one shot which expects to be called by the timer unit
* Metadata will cause it to be made available on all frontend servers when loaded
    * It technically could run anywhere with etcd, just limiting its loaded footprint

> Special Deployment Note:
> * Put the admin e-mail and domain into etcd
> ```
> /usr/bin/etcdctl set /domain/name <domain>
> /usr/bin/etcdctl set /domain/email <email>
> ```
> * Manually run the wac-acme container once to obtain certificates the first time
> ```
> sudo docker run --net host --name acme chadautry/wac-acme
> ```

[letsencrypt-renewal.timer](units/letsencrypt-renewal.timer)
```yaml
[Unit]
Description=Letsencrpyt renewal timer

[Timer]
OnCalendar=*-*-01 05:00:00
RandomizedDelaySec=60

[X-Fleet]
MachineMetadata=frontend=true
```
* Executes once a month on the 1st at 5:00
    * Avoid any DST confusions by avoiding the midnight hours
* Assuming this gets popular (yeah right), add a 1 minute randomized delay to not pound letsencrypt
* Automagically executes the letsencrypt-renewal.service based on name
* Not global so there will only be one instance

### nginx static app update unit
Want to load app once, and have it distribute automatically

### backend discovery unit
Sets a watch on the backend discovery location, and when it changes templates out the nginx confi

[backend-discovery-watcher.service](units/backend-discovery-watcher.service)
```yaml
[Unit]
Description=Watches for backened instances
# Dependencies
Requires=etcd2.service

# Ordering
After=etcd2.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-nginx-config-templater
ExecStartPre=-/usr/bin/docker rm nginx-templater
ExecStart=/usr/bin/etcdctl watch /discovery/backend
ExecStartPost=-/usr/bin/docker run --name nginx-templater --net host \
-v /var/nginx:/usr/var/nginx -v /var/ssl:/etc/nginx/ssl:ro \
chadautry/wac-nginx-config-templater
Restart=always

[X-Fleet]
Global=true
MachineMetadata=frontend=true
```
* Starts a watch for changes in the backend discovery path
* Once the watch starts, executes the config templating container
    * Local volume mapped in for the templated config to be written to
    * Doesn't error out (TODO move to a secondary unit to be safely concurrent)
* If the watch is ever satisfied, the unit will exit
* Automatically restarted, causing a new watch and templater execution
* Blindly runs on all frontend tagged instances

## API Backend
These are the units for an api backend, including authentication. A cluster could have multiple backend processes, just change the tagging from 'backend' to some named process (and change the docker process name)

#### node config watcher
This unit watches the node config values in etcd, and templates them to a file for the node app when they change

[node-config-watcher.service](units/node-config-watcher.service)
```yaml
[Unit]
Description=Watches for node config changes
# Dependencies
Requires=etcd2.service

# Ordering
After=etcd2.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-node-config-templater
ExecStartPre=-/usr/bin/docker rm node-templater
ExecStart=/usr/bin/etcdctl watch /node/config
ExecStartPost=-/usr/bin/docker run --name node-templater --net host \
-v /var/nodejs:/usr/var/nodejs -v /var/ssl:/etc/nginx/ssl:ro \
chadautry/wac-node-config-templater
ExecStartPost=-/usr/bin/docker stop backend-node-container
Restart=always

[X-Fleet]
Global=true
MachineMetadata=backend=true
```
* Starts a watch for changes in the top node config path
* Once the watch starts, executes the config templating container
    * Local volume mapped in for the templated config to be written to
    * Doesn't error out
* Once the config is templated, stops the node container (it will be restarted by its unit)
* If the watch is ever satisfied, the unit will exit
* Automatically restarted, causing a new watch and templater execution
* Blindly runs on all backend tagged instances

> Special Deployment Note:
> * Put the node authorization config values into etcd
> ```
> /usr/bin/etcdctl set /node/config/token_secret <Created Private Key>
> /usr/bin/etcdctl set /node/config/auth/google/client_id <Google Client ID>
> /usr/bin/etcdctl set /node/config/auth/google/redirect_uri <Google Redirect URI>
> /usr/bin/etcdctl set /node/config/auth/google/secret <Google OAuth Secret>
> ```

### nodejs unit
The main application unit, it is simply a docker container with Node.js installed and the code to be executed mounted inside

[nodejs.service](units/nodejs.service)
```yaml
[Unit]
Description=NodeJS Backend API
# Dependencies
Requires=docker.service
Requires=node-config-watcher.service

# Ordering
After=docker.service
After=node-config-watcher.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-node
ExecStartPre=-/usr/bin/docker rm -f backend-node-container
ExecStart=/usr/bin/docker run --name backend-node-container -p 8080:80 -p 4443:443 \
-v /var/nodejs:/app:ro \
chadautry/wac-node
ExecStop=-/usr/bin/docker stop backend-node-container
Restart=always

[X-Fleet]
Global=true
MachineMetadata=backend=true
```
* requires docker
* requires the configuration templater
* Starts a customized nodejs docker container
    * Takes the app from local drive
* Blindly runs on all backend tagged instances

### nodejs code update unit
* Need to distribute code accross all backend instances
* Need to restart the local Node server when new code is on the machine

### backend publishing unit
Publishes the backend host into etcd at an expected path for the frontend to route to

[backend-publishing.service](units/backend-publishing.service)
```yaml
[Unit]
Description=Backend Publishing
# Dependencies
Requires=etcd2.service

# Ordering
After=etcd2.service

[Service]
ExecStart=/bin/sh -c "while true; do etcdctl set /discovery/backend/%H '%H' --ttl 60;sleep 45;done"
ExecStop=/usr/bin/etcdctl rm /discovery/backend/%H

[X-Fleet]
Global=true
MachineMetadata=backend=true
```
* requires etcd
* Publishes host into etcd every 45 seconds with a 60 second duration
* Deletes host from etcd on stop
* Blindly runs on all backend tagged instances

### JWT Encryption Keys
* Need a manual command to generate a new key (placing it in etcd)
* Need to watch the new key, and restart the Node.js unit when it changes

### RethinkDB unit

## Unit Files
[![Build Status](https://travis-ci.org/chad-autry/wac-bp.svg?branch=master)](https://travis-ci.org/chad-autry/wac-bp)

The unit files under the units directory have been extracted from this document and pushed back to the repo.

## Addendum

### Tips and Tools
* Pre-create/retrieve Unit files externally
* Script to launch units
* Sftp to move files easily
