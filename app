#!/usr/bin/env bash

# https://gist.github.com/epiloque/8cf512c6d64641bde388
parse_yaml() {
    local prefix=$2
    local s
    local w
    local fs
    s='[[:space:]]*'
    w='[a-zA-Z0-9_]*'
    fs="$(echo @|tr @ '\034')"
    sed -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s[:-]$s\(.*\)$s\$|\1$fs\2$fs\3|p" "$1" |
    awk -F"$fs" '{
    indent = length($1)/2;
    vname[indent] = $2;
    for (i in vname) {if (i > indent) {delete vname[i]}}
        if (length($3) > 0) {
            vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
            printf("%s%s%s=(\"%s\")\n", "'"$prefix"'",vn, $2, $3);
        }
    }' | sed 's/_=/+=/g'
}

# define timeout function if it does not exist. This is to support continued developed on OS X
if [ "`type -t timeout`" != 'function' ]; then
    function timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }
fi

function log {
   echo "[${SCRIPT}] => ${1}"
}

function command_not_found {
    log "One of the following arguments was expected but not supplied: ${command_list:2}"
    exit 1
}

# function appends arguments required to build container images
# these values should be extracted from this script, written to Consul and
# injected during the provisioning pipeline
function run {
    echo "now executing: ${@:1}"
    compiled_binary_path=${BINARY_PATH} image_name=${IMAGE_NAME} ${@:1}
}

# read initial argument and validate
COMMAND=$1
SCRIPT=`basename "$0"`
declare -a SUPPORTED_COMMANDS=(package build publish clean promote start stop restart clean-all logs mvn ssh test)
command_list=$(printf ", %s" "${SUPPORTED_COMMANDS[@]}")

# guard clause for unexpected commands
if [ -z "${COMMAND}" ] || [[ ! "${SUPPORTED_COMMANDS[@]}" =~ "${COMMAND}" ]]
then
    command_not_found
fi

# build the container name base on parent directory name
PARENT_DIR="$(basename "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" | sed 's/-//g' | sed 's/_//g' )"
CONTAINER_PREFIX="$( echo $PARENT_DIR | tr '[:upper:]' '[:lower:]')"
IMAGE_NAME=$CONTAINER_PREFIX"_app"
CONTAINER_NAME=$CONTAINER_PREFIX"_app_1"

# read in app configurations
log "Reading app configurations from 'app.yml' file"
parse_yaml app.yml "app_"
echo "" & eval $(parse_yaml app.yml "app_")

# specific to applications using maven
ARTIFACT_ID=$(grep --max-count=1 '<artifactId>' pom.xml | awk -F '>' '{ print $2 }' | awk -F '<' '{ print $1 }')
VERSION=$(grep --max-count=1 '<version>' pom.xml | awk -F '>' '{ print $2 }' | awk -F '<' '{ print $1 }')
BINARY_FILENAME="${ARTIFACT_ID}-${VERSION}.jar"
BINARY_PATH="target/${BINARY_FILENAME}"
#IMAGE_NAME=${IMAGE_REPO_URL}/${IMAGE_REPO_NAME}:${ARTIFACT_ID}-${VERSION}
IMAGE_NAME=${app_publish_image_repo_url}/${app_publish_image_repo_name}:${ARTIFACT_ID}-${VERSION}
log "IMAGE_NAME: ${IMAGE_NAME}"

# set working directory as parent directory of script
cd "$(dirname "$0")"

##
# implement publish contract
# ./app [ package | build | publish | clean ]
##
if [ ${COMMAND} == "package" ]
then
    # start dev container used to package assets
    run docker-compose -f docker-compose-dev.yml up -d app

    # build asset
    docker exec ${CONTAINER_NAME} mvn clean package
elif [ ${COMMAND} == "build" ]
then
    # app-image definition is contained in docker-compose-dev.yml file
    run docker-compose -f docker-compose-dev.yml build app-image
elif [ ${COMMAND} == "publish" ]
then
    # publish new image to image repo
    eval "$(aws ecr get-login --profile ss_prod)"
    docker push ${IMAGE_NAME}

    # deploy to dev environment
    # You can not pass the cluster name dynamically to the ECS CLI, so you must update the ECS config file dynamically
    # with the desired cluster name prior to execute the deployment
    cluster=${app_promote_stages_dev_cluster_name}
    log "Deploying to dev cluster [${cluster}]..."

    # update ecs config
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # Mac OSX
        sed -i '' -e "s/cluster.*/cluster                     = ${cluster}/g" ~/.ecs/config
    else
        # Linux.
        sed -i -e "s/cluster.*/cluster                     = ${cluster}/g" ~/.ecs/config
    fi

    # NOTE: Since ECS does not support docker-compose v2 syntax, we need to generate a docker-compose v1 compliant file.
    # Additionally, since ECS does not support arguments in the docker-compose file, we must replace all arguments with
    # actually values in the file before starting a new container.

    # create a new docker-compose-ecs.yml file that will be used for ECS deployment
    rm -rf docker-compose-ecs.yml
    cp docker-compose-ecs-template.yml docker-compose-ecs.yml

    # replace arguments with actual values
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # Mac OSX
        sed -i '' -e "s|\${IMAGE_NAME}|${IMAGE_NAME}|g" docker-compose-ecs.yml
    else
        # Linux.
        sed -i -e "s|\${IMAGE_NAME}|${IMAGE_NAME}|g" docker-compose-ecs.yml
    fi

    # stop the running service
    ecs-cli compose --project-name ${ARTIFACT_ID} --file docker-compose-ecs.yml service stop

    # launch service using updated docker-compose file
    # the ECS CLI occasionally hangs even though service launches successfully, so timeout added
    timeout 180s ecs-cli compose --project-name ${ARTIFACT_ID} --file docker-compose-ecs.yml service up
elif [ ${COMMAND} == "clean" ]
then
    # stop dev container
    run docker-compose -f docker-compose-dev.yml down


##
# implement promote contract
# ./app [ promote ]
##
elif [ ${COMMAND} == "promote" ]
then
    supplied_env=${2}

    if [[ ${supplied_env} == "qa"* ]]; then
        cluster=${app_promote_stages_qa_cluster_name}
    elif [[ ${supplied_env} == "prod"* ]]; then
        cluster=${app_promote_stages_prod_cluster_name}
    else
        log "Promotion to stage '${supplied_env}' is not defined. The script is exiting prematurely."
        exit 1
    fi

    # deploy to dev environment
    # You can not pass the cluster name dynamically to the ECS CLI, so you must update the ECS config file dynamically
    # with the desired cluster name prior to execute the deployment
    log "Promoting to ${supplied_env} cluster [${cluster}]..."

    # update ecs config
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # Mac OSX
        sed -i '' -e "s/cluster.*/cluster                     = ${cluster}/g" ~/.ecs/config
    else
        # Linux.
        sed -i -e "s/cluster.*/cluster                     = ${cluster}/g" ~/.ecs/config
    fi

    # create a new docker-compose-ecs.yml file that will be used for ECS deployment
    rm -rf docker-compose-ecs.yml
    cp docker-compose-ecs-template.yml docker-compose-ecs.yml

    # replace arguments with actual values
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # Mac OSX
        sed -i '' -e "s|\${IMAGE_NAME}|${IMAGE_NAME}|g" docker-compose-ecs.yml
    else
        # Linux.
        sed -i -e "s|\${IMAGE_NAME}|${IMAGE_NAME}|g" docker-compose-ecs.yml
    fi

    # stop the running service
    ecs-cli compose --project-name ${ARTIFACT_ID} --file docker-compose-ecs.yml service stop

    # launch service using updated docker-compose file
    # the ECS CLI occasionally hangs even though service launches successfully, so timeout added
    timeout 180s ecs-cli compose --project-name ${ARTIFACT_ID} --file docker-compose-ecs.yml service up

##
# implement develop contract
# ./app [ start | start dev | stop | stop dev | restart | restart dev | clean-all | logs | mvn | ssh ]
##
elif [ $COMMAND == "test" ]
then
    if [ "`type -t timeout`" != 'function' ]; then
        echo "The function does not exist"
    else
        echo "The function does exist"
    fi
    #timeout 5s sleep 10s
elif [ $COMMAND == "start" ]
then
    # only './app start' and './app start dev' supported
    # eval "$(aws ecr get-login --profile ss_prod)"
    run docker-compose $([ -z ${2} ] && echo -f docker-compose.yml || echo -f docker-compose-dev.yml) up -d app
elif [ $COMMAND == "stop" ]
then
    # only './app stop' and './app stop dev' supported
    run docker-compose $([ -z ${2} ] && echo -f docker-compose.yml || echo -f docker-compose-dev.yml) down
elif [ $COMMAND == "restart" ]
then
    # only './app restart' and './app restart dev' supported
    run docker-compose $([ -z ${2} ] && echo -f docker-compose.yml || echo -f docker-compose-dev.yml) down
	run docker-compose $([ -z ${2} ] && echo -f docker-compose.yml || echo -f docker-compose-dev.yml) up -d app
elif [ $COMMAND == "clean-all" ]
then
    run docker-compose -f docker-compose.yml -f docker-compose-dev.yml down --rmi all
elif [ $COMMAND == "logs" ]
then
    docker logs -f ${CONTAINER_NAME}
elif [ $COMMAND == "mvn" ]
then
    # pass all additional args to the maven cli
	docker exec ${CONTAINER_NAME} mvn "${@:2}"
elif [ $COMMAND == "ssh" ]
then
    docker exec -it ${CONTAINER_NAME} bash -c "export TERM=xterm; exec bash"
else
    command_not_found
fi
