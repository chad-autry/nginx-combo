# web-application cluster boiler-plate
Documentation and copy-pasteable boilerplate for running a full web application in a micro-services style. Many pieces are optional and could be swapped out to match others desires.

### Assumptions and Opinions
* Alpine Linux is my prefered containerized OS, and the choice I've made for images
* CoreOS is the chosen host operating system
  * fleet comes for free for orchestration
  * etcd comes for free for a key value store

### Requirements and Features
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

### Architecture

### Deployment

## Nginx
At this point [nginx:alpine-stable](https://github.com/docker-library/docs/tree/master/nginx) seems suitable for my needs. I started [wac-nginx](https://github.com/chad-autry/wac-nginx), but there is no need to re-invent containers if suitable ones already exist. If/when I want different 3rd party modules compiled in I'll take the official image as a starting point.

To deploy I like to copy the static files into a directory on the host instead of building a new docker image (with a private docker registry that preference could easily change). /var/www is a good location.

Use a temporary ftp container (such as atmoz/sftp) to easily copy the files over. Don't forget to change file permissions and open the port for sftp. Stop and delete the container when done.
```shell
sudo docker run -d --name sftp_server -v /var/www:/home/sftpuser/www -p 2222:22 atmoz/sftp sftpuser:sftppassword:1001
```

Once your files are copied over, you can run the tagged release of the Nginx container.
```shell
docker run --name nginx -p 80:80 -v /var/www:/usr/share/nginx/html:ro -d nginx:stable-alpine
```
