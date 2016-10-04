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
Just an example. Starts fleet, bootstraps a single static etcd cluster with only the single instance
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
      metadata: "frontend=true"
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
-v /var/www:/usr/share/nginx/html:ro -v /etc/ssl:/etc/nginx/ssl:ro \
-v /var/nginx:/usr/var/nginx:ro \
-d chadautry/wac-nginx
Restart=on-failure

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

[X-Fleet]
Global=true
MachineMetadata=frontend=true
```
* Watches config files
* Automatically calls nginx-reload.service on change (because of matching unit name)
* Blindly runs on all frontend tagged instances

### acme challenge response watcher
[acme-response-watcher.service](units/acme-response-watcher.service)
```yaml
[Unit]
Description=Watches for distributed acme challenge responses
# Dependencies
Requires=etcd.service

# Ordering
After=etcd.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-nginx-config-templater
ExecStartPre=-/usr/bin/docker rm nginx-templater
ExecStart=/usr/bin/etcdctl watch /acme/watched
ExecStartPost=-/usr/bin/docker run --name nginx-templater --net host \
-v /var/nginx:/usr/var/nginx chadautry/wac-nginx-config-templater
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

### SSL Certificate Syncronization
[certificate-sync.service](units/certificate-sync.service)
```yaml
[Unit]
Description=SSL Certificate Syncronization
# Dependencies
Requires=etcd.service

# Ordering
After=etcd.service

[Service]
ExecStart=/usr/bin/etcdctl watch  /config/ssl
ExecStartPost=/usr/bin/etcdctl get /config/ssl > /etc/ssl/cert.crt
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

### letsencrypt renewal unit
* Scheduled to run once a month
* Writes acme challenge response to etcd (< 1 MB)
* Writes certificate to etcd (< 1 MB)

### nginx static app update unit
Want to load app once, and have it distribute automatically

### api endpoint discovery unit
## Backend
### nodejs unit
### nodejs code update unit
### api endpoint publishing unit
### RethinkDB unit

## Unit Files
[![Build Status](https://travis-ci.org/chad-autry/wac-bp.svg?branch=master)](https://travis-ci.org/chad-autry/wac-bp)

The unit files under the units directory have been extracted from this document and pushed back to the repo.

## Addendum

### Tips and Tools
* Pre-create/retrieve Unit files externally
* Script to launch units
* Sftp to move files easily
