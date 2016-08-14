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
* Configure SAN disks
* Create machine instances
* Firewall
* Create fleet cluster
    * Tag instances
* Machine instance monitoring

## Frontend
### nginx unit
The main unti for the front end, nginx is the static file server and reverse proxy. Can have redundant instances.

[nginx.service](units/nginx.service)
```yaml
[Unit]
Description=NGINX
After=docker.service
Requires=docker.service
Before=nginx-certificate-update.service nginx-site-update.service
Wants=nginx-certificate-update.service nginx-site-update.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-nginx
ExecStartPre=-/usr/bin/docker rm nginx
ExecStart=/usr/bin/docker run --name nginx -p 80:80 -p 443:443 \
-v /var/www:/usr/share/nginx/html:ro -v /etc/ssl:/etc/nginx/ssl:ro \
-d chadautry/wac-nginx

[X-Fleet]
Global=true
MachineMetadata=frontend=true
```
requires docker
wants cert update
wants app update
Starts an nginx docker container
    configured to route http --> https (except letsencrypt requests)
    Takes html from local drive
    Takes certs from local drive
runs on front end tagged instances

### letsencrypt renewal unit
requires san disk

### nginx certificate update unit
requires san disk

### nginx static app update unit
requires san disk

### api endpoint discovery unit
## Backend
### nodejs unit
### nodejs code update unit
### api endpoint publishing unit
### RethinkDB unit
## Addendum
### SAN replacement possibilities
* Baked in Docker
* Shared read only disks

### Tips and Tools
* Pre-create/retrieve Unit files externally
* Script to launch units
* Sftp to move files easily