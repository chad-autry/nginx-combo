# web-application cluster boiler-plate
Documentation and scripts for running a full web application in a micro-services style. Many pieces are optional and could be swapped out to match others desires.

## Transitioning to Ansible
Currentlly transitioning from fleet to ansible

## Unit Files, Scripts, Playbooks
[![Build Status](https://travis-ci.org/chad-autry/wac-bp.svg?branch=master)](https://travis-ci.org/chad-autry/wac-bp)

The unit files, scripts, and playbooks in the dist directory have been extracted from this document and pushed back to the repo.

## Assumptions and Opinions
* Alpine Linux is my prefered containerized OS, and the choice I've made for images
* CoreOS is the chosen host operating system
* Ansible is used for orchestration

## Requirements and Features
* Dockerized nginx container to host static site
  * Forward's nginx logs to the docker service, [loggly logging strategy article](https://www.loggly.com/blog/top-5-docker-logging-methods-to-fit-your-container-deployment-strategy/)
  * Automatically reconfigures and refreshes nginx config based on routing configuration provided through etcd
  * SSL termination
  * By default forward http connections to https
  * Have a configuration mode which allows initial letsencrypt validation over http
* Https certificate from letsencrypt with autorenewal
* Containerized Node.js server
  * Publishes to etcd for discovery
  * Expets DB proxy on localhost
  * Oauth & Oauth2 Termination
    * JWT generation and validation
* Dockerized RethinkDB
* Ansible based deployment and initialization

## Externalities
* Configure DNS
* Create tagged machine instances
* Create Ansible inventory (or use dynamic inventory script!)
* Firewall
* Machine instance monitoring

## Ansible Deployment
The machine used for a controller will need SSH access to all the machines being managed. You can use one of the instances being managed, on GCE [cloud shell](https://cloud.google.com/shell/docs/) is a handy resource to use. I'm personally running in GCE using [wac-gce-ansible](https://github.com/chad-autry/wac-gce-ansible)

### Ansible Inventory
Here is an example inventory. wac-bp operates on machines based on the group they belong to. You can manually create the inventory file with the hosts to manage, or use a dynamic inventory script for your cloud provider.

```
hostnameone
hostnametwo

[tag_etcd]
hostnameone

[tag_rethinkdb]
hostnameone

[tag_frontend]
hostnametwo

[tag_backend]
hostnametwo
```

### group_vars/all
The all variables file contains all the container versions to use.

[group_vars/all](dist/ansible/group_vars/all)
```yaml
---
# CoreOS can't have python installed at the normal /etc/bin. Override in inventory for localhost (if not CoreOS)
ansible_python_interpreter: /opt/bin/python
# The host value which will be templated out for intra-machine connectivity. Match your manual inventory or dynamic inventory variable
internal_ip_name: gce_private_ip
# The unique name of machine instances to be used in templates
machine_name: gce_name

# Variables which get set into etcd (some of them are private!) needed by other applications
domain_name: <domain_name>
domain_email: <domain_email>
rethinkdb_web_password: <rethinkdb_web_password>
jwt_token_secret: <jwt_token_secret>
google_client_id: <google_client_id>
google_rediret_uri: <google_redirect_uri>
google_auth_secret: <google_auth_secret>

# The container versions to use
wac-python_version: latest
etcd_version: latest
nginx_version: latest
backend-discovery-watcher_version: latest
```

## Playbooks
### site.yml
The main playbook that deploys or updates a cluster

[site.yml](dist/ansible/site.yml)
```yml
# Make sure python is installed
- hosts: all:!localhost
  gather_facts: false
  become: true
  roles:
    - coreos-python
    
# Place a full etcd on the etcd hosts
- hosts: tag_etcd
  become: true
  roles:
    - { role: etcd, proxy_etcd: False }

# Set the etcd values (if required) from the first etcd host
- hosts: tag_etcd[0]
  become: true
  roles:
    - populate_etcd

# Place a proxy etcd everywhere except the etcd hosts
- hosts: all:!tag_etcd:!localhost
  become: true
  roles:
    - { role: etcd, proxy_etcd: True }
    
# nginx
- hosts: tag_frontend
  become: true
  roles:
    - frontend
```

## Roles
The roles used by the playbooks above

### coreos-ansible
Install Python onto CoreOS hosts

[roles/coreos-python/tasks/main.yml](dist/ansible/roles/coreos-python/tasks/main.yml)
```yml
- name: Check if bootstrap is needed
  raw: stat /opt/bin/python
  register: need_bootstrap
  ignore_errors: True

- name: Run bootstrap.sh
  script: bootstrap.sh
  when: need_bootstrap | failed
```

[roles/coreos-python/files/bootstrap.sh](dist/ansible/roles/coreos-python/files/bootstrap.sh)
```bash
#/bin/bash

set -e

cd

if [[ -e /opt/bin/python ]]; then
  exit 0
fi

PYPY_VERSION=5.1.0

if [[ -e $HOME/pypy-$PYPY_VERSION-linux64.tar.bz2 ]]; then
  tar -xjf $HOME/pypy-$PYPY_VERSION-linux64.tar.bz2
  rm -rf $HOME/pypy-$PYPY_VERSION-linux64.tar.bz2
else
  wget -O - https://bitbucket.org/pypy/pypy/downloads/pypy-$PYPY_VERSION-linux64.tar.bz2 |tar -xjf -
fi

mkdir -p /opt/bin

mv -n pypy-$PYPY_VERSION-linux64 /opt/bin/pypy

## library fixup
mkdir -p /opt/bin/pypy/lib
ln -snf /lib64/libncurses.so.5.9 /opt/bin/pypy/lib/libtinfo.so.5

cat > /opt/bin/python <<EOF
#!/bin/bash
LD_LIBRARY_PATH=/opt/bin/pypy/lib:$LD_LIBRARY_PATH exec /opt/bin/pypy/bin/pypy "\$@"
EOF

chmod +x /opt/bin/python
/opt/bin/python --version
```

### etcd
Deploys or redeploys the etcd instance on a host. Etcd is persistent, but if the cluster changes wac-bp blows it away instead of attempting to add/remove instances.

[roles/etcd/tasks/main.yml](dist/ansible/roles/etcd/tasks/main.yml)
```yml
# template out the systemd service unit on the etcd hosts
- name: etcd template
  template:
    src: etcd.service
    dest: /etc/systemd/system/etcd.service
  register: etcd_template

- name: wipe out etcd directory
  file:
    state: absent
    path: /var/etcd
  when: etcd_template | changed
    
- name: ensure etcd directory is present
  file:
    state: directory
    path: /var/etcd
  when: etcd_template | changed

- name: start/restart the service if template changed
  systemd:
    daemon_reload: yes
    state: restarted
    name: etcd.service
  when: etcd_template | changed
```

[etcd.service](dist/ansible/roles/etcd/templates/etcd.service)
```yaml
[Unit]
Description=etcd
# Dependencies
Requires=docker.service

# Ordering
After=docker.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-etcdv2:{{etcd_version}}
ExecStartPre=-/usr/bin/docker rm etcd
ExecStart=/usr/bin/docker run --name etcd --net host -p 2380:2380 -p 2379:2379 \
-v /var/etcd:/var/etcd \
chadautry/wac-etcdv2:{{etcd_version}} \
{% if not proxy_etcd %}
--initial-advertise-peer-urls http://{{hostvars[inventory_hostname][internal_ip_name]}}:2380 \
--listen-peer-urls http://{{hostvars[inventory_hostname][internal_ip_name]}}:2380 \
--advertise-client-urls http://{{hostvars[inventory_hostname][internal_ip_name]}}:2379 \
--data-dir /var/etcd \
--initial-cluster-state new \
{% endif %}
{% if proxy_etcd %}
--proxy on \
{% endif %}
--name {{hostvars[inventory_hostname][machine_name]}} \
--listen-client-urls http://{{hostvars[inventory_hostname][internal_ip_name]}}:2379,http://127.0.0.1:2379 \
--initial-cluster {% for host in groups['tag_etcd']  %}{{hostvars[host][machine_name]}}=http://{{hostvars[host][internal_ip_name]}}:2380{% if not loop.last %},{% endif %}{% endfor %}

Restart=always
````
* requires docker
* takes version from etcd_version variable
* writes different lines for proxy mode or standard
* uses the internal ip variable configured
* walks the etcd hosts for the initial cluster

### populate_etcd
This role sets values into etcd from the Ansible config when the etcd cluster has been recreated. It only needs to be executed from a single etcd machine.

[roles/populate_etcd/tasks/main.yml](dist/ansible/roles/populate_etcd/tasks/main.yml)
```yml
# Condititionally import the populate.yml, so we don't have to see all the individual set tasks excluded in the output
- include: populate.yml
  static: no
  when: (etcd_template | changed) or (force_populate_etcd is defined)
```

[roles/populate_etcd/tasks/populate.yml](dist/ansible/roles/populate_etcd/tasks/populate.yml)
```yml
- name: /usr/bin/etcdctl set /domain/name <domain>
  command: /usr/bin/etcdctl set /domain/name {{domain_name}}
  
- name: /usr/bin/etcdctl set /domain/email <email>
  command: /usr/bin/etcdctl set /domain/email {{domain_email}}
  
- name: /usr/bin/etcdctl set /rethinkdb/pwd <Web Authorization Password>
  command: /usr/bin/etcdctl set /rethinkdb/pwd {{rethinkdb_web_password}}
  
- name: /usr/bin/etcdctl set /node/config/token_secret <Created Private Key>
  command: /usr/bin/etcdctl set /node/config/token_secret {{jwt_token_secret}}

- name: /usr/bin/etcdctl set /node/config/auth/google/client_id <Google Client ID>
  command: /usr/bin/etcdctl set /node/config/auth/google/client_id {{google_client_id}}
  
- name: /usr/bin/etcdctl set /node/config/auth/google/redirect_uri <Google Redirect URI>
  command: /usr/bin/etcdctl set /node/config/auth/google/redirect_uri {{google_rediret_uri}}
  
- name: /usr/bin/etcdctl set /node/config/auth/google/secret <Google OAuth Secret>
  command: /usr/bin/etcdctl set /node/config/auth/google/secret {{google_auth_secret}}
```

### frontend
The front end playbook sets up the nginx unit, the nginx file watching & reloading units, the letsencrypt renewal units, and finally pushes the front end application across (tagged so it can be executed alone)

[roles/frontend/tasks/main.yml](dist/ansible/roles/frontend/tasks/main.yml)
```yml
# Ensure the frontend directories are created
- name: ensure www directory is present
  file:
    state: directory
    path: /var/www
    
- name: ensure nginx directory is present
  file:
    state: directory
    path: /var/nginx
    
- name: ensure ssl directory is present
  file:
    state: directory
    path: /var/ssl
    
# Import backend route configurator (creates config before nginx starts)
- include: backend-discovery-watcher.yml

# Import nginx task file
- include: nginx.yml

# Import letsencrypt tasks

# Import etcd route discovery task

# Import application push task
```

## nginx
Hosts static files, routes to backends, terminates SSL

[roles/frontend/tasks/nginx.yml](dist/ansible/roles/frontend/tasks/nginx.yml)
```yml
# template out the systemd service unit
- name: nginx.service template
  template:
    src: nginx.service
    dest: /etc/systemd/system/nginx.service
  register: nginx_template
    
- name: start/restart the service if template changed
  systemd:
    daemon_reload: yes
    state: restarted
    name: nginx.service
  when: nginx_template | changed
```

[nginx.service](dist/ansible/roles/frontend/templates/nginx.service)
```yaml
[Unit]
Description=NGINX
# Dependencies
Requires=docker.service

# Ordering
After=docker.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-nginx:{{nginx_version}}
ExecStartPre=-/usr/bin/docker rm nginx
ExecStart=/usr/bin/docker run --name nginx -p 80:80 -p 443:443 \
-v /var/www:/usr/share/nginx/html:ro -v /var/ssl:/etc/nginx/ssl:ro \
-v /var/nginx:/usr/var/nginx:ro \
chadautry/wac-nginx
Restart=always
```
* requires docker
* Starts a customized nginx docker container
    * Version comes from variables
    * Takes server config from local drive
    * Takes html from local drive
    * Takes certs from local drive

## backend discovery
Sets a watch on the backend discovery location, and when it changes templates out the nginx conf
[roles/frontend/tasks/backend-discovery-watcher.yml](dist/ansible/roles/frontend/tasks/backend-discovery-watcher.yml)
```yml
# template out the systemd service unit
- name: backend-discovery-watcher.service template
  template:
    src: backend-discovery-watcher.service
    dest: /etc/systemd/system/backend-discovery-watcher.service:{{backend-discovery-watcher_version}}
  register: backend-discovery-watcher_template
    
- name: start/restart the service if template changed
  systemd:
    daemon_reload: yes
    state: restarted
    name: backend-discovery-watcher.service
  when: backend-discovery-watcher_template | changed
```

[backend-discovery-watcher.service](dist/ansible/roles/frontend/templates/backend-discovery-watcher.service)
```yaml
[Unit]
Description=Watches for backened instances
# Dependencies
Requires=etcd.service

# Ordering
After=etcd.service

# Restart when dependency restarts
PartOf=etcd.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-nginx-config-templater
ExecStartPre=-/usr/bin/docker rm nginx-templater
ExecStart=/usr/bin/etcdctl watch /discovery/backend
ExecStartPost=-/usr/bin/docker run --name nginx-templater --net host \
-v /var/nginx:/usr/var/nginx -v /var/ssl:/etc/nginx/ssl:ro \
chadautry/wac-nginx-config-templater
Restart=always
```
* Restarted if etcd restarts
* Starts a watch for changes in the backend discovery path
* Once the watch starts, executes the config templating container
    * Local volume mapped in for the templated config to be written to
    * Local ssl volume mapped in for the template container to read
    * Doesn't error out (TODO move to a secondary unit to be safely concurrent)
* If the watch is ever satisfied, the unit will exit
* Automatically restarted, causing a new watch and templater execution

## Frontend Units


### nginx reloading units
A pair of units are responsible for reloading nginx instances on file changes

[nginx-reload.service](dist/units/nginx-reload.service)
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

[nginx-reload.path](dist/units/started/nginx-reload.path)
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

[acme-response-watcher.service](dist/units/started/acme-response-watcher.service)
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

[certificate-sync.service](dist/units/started/certificate-sync.service)
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

[letsencrypt-renewal.service](dist/units/letsencrypt-renewal.service)
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

[letsencrypt-renewal.timer](dist/units/started/letsencrypt-renewal.timer)
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



## API Backend
These are the units for an api backend, including authentication. A cluster could have multiple backend processes, just change the tagging from 'backend' to some named process (and change the docker process name)

#### node config watcher
This unit watches the node config values in etcd, and templates them to a file for the node app when they change

[node-config-watcher.service](dist/units/started/node-config-watcher.service)
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
ExecStart=/usr/bin/etcdctl watch --recursive /node/config
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

[nodejs.service](dist/units/started/nodejs.service)
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

[backend-publishing.service](dist/units/started/backend-publishing.service)
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

### rethinkdb proxy unit
A rethinkdb proxy on localhost for nodejs units to connect to

[rethinkdb-proxy.service](dist/units/started/rethinkdb-proxy.service)
```yaml
[Unit]
Description=RethinkDB Proxy
# Dependencies
Requires=docker.service
Requires=etcd2.service

# Ordering
After=docker.service
After=etcd2.service

[Service]
ExecStartPre=-mkdir /var/rethinkdbproxy
ExecStartPre=-/usr/bin/docker pull chadautry/wac-rethinkdb-config-templater
ExecStartPre=-/usr/bin/docker run \
--net host --rm \
-v /var/rethinkdbproxy:/usr/var/rethinkdb \
chadautry/wac-rethinkdb-config-templater "emptyHost"
ExecStartPre=-/usr/bin/docker pull chadautry/wac-rethinkdb
ExecStartPre=-/usr/bin/docker rm -f rethinkdb-proxy
ExecStartPre=-rm /var/rethinkdbproxy/pid_file
ExecStart=/usr/bin/docker run --name rethinkdb-proxy \
-v /var/rethinkdbproxy:/usr/var/rethinkdb \
-p 29017:29015 -p29018:29016 -p 8082:8080 \
chadautry/wac-rethinkdb proxy --config-file /usr/var/rethinkdb/rethinkdb.conf
Restart=always

[X-Fleet]
Global=true
MachineMetadata=backend=true
```
* requires docker
* Configures the instance, will not exclude any host from join list
* Pulls the image
* Removes the container
* Starts a rethinkdb container in proxy mode
* All ports shifted by 2, so it won't conflict with a non-proxy node
* Blindly runs on all backend tagged instances

## Database

### rethinkdb unit
A rethinkdb node

[rethinkdb.service](dist/units/started/rethinkdb.service)
```yaml
[Unit]
Description=RethinkDB
# Dependencies
Requires=docker.service
Requires=etcd2.service

# Ordering
After=docker.service
After=etcd2.service

[Service]
ExecStartPre=-mkdir /var/rethinkdb
ExecStartPre=-/usr/bin/docker pull chadautry/wac-rethinkdb-config-templater
ExecStartPre=-/usr/bin/docker run \
--net host --rm \
-v /var/rethinkdb:/usr/var/rethinkdb \
chadautry/wac-rethinkdb-config-templater %H
ExecStartPre=-/usr/bin/docker pull chadautry/wac-rethinkdb
ExecStartPre=-/usr/bin/docker rm -f rethinkdb
ExecStartPre=-rm /var/rethinkdb/pid_file
ExecStart=/usr/bin/docker run --name rethinkdb \
-v /var/rethinkdb:/usr/var/rethinkdb \
-p 29015:29015 -p29016:29016 -p 8081:8080 \
chadautry/wac-rethinkdb --config-file /usr/var/rethinkdb/rethinkdb.conf
Restart=always

[X-Fleet]
Global=true
MachineMetadata=database=true
```
* requires docker
* Configures the instance, will exclude its own host from the join list
* Pulls the image
* Removes the container
* Starts a rethinkdb container
* HTTP shifted to 8081 so it won't conflict with nginx if colocated
* Blindly runs on all database tagged instances

> DB Instance Prep:
> There is some prep that needs to be done manually on each DB instance
> ```
> docker run --rm -v /var/rethinkdb:/usr/var/rethinkdb chadautry/wac-rethinkdb create -d /var/rethinkdb/data
> sudo etcd set /discovery/database/<host> <host>
> ```
