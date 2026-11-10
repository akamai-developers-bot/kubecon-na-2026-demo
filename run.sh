#!/bin/bash

# GitHub token (classic) permissions
# repo
# admin:org --> read:org
# delete_repo

# script colors
export blue="\e[1;34m"
export green="\e[1;32m"
export yellow="\e[1;33m"
export red="\e[1;31m"
export grey="\e[1;37m"
export reset="\e[m"

readonly workdir=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
readonly success="\U0002714\U000FE0F"
readonly fail="\U0002716\U000FE0F"

# trap 'cleanup' ERR

##### utility funcs #####
cleanup() {
    if [[ $? != 0 ]] || [[ $CLEANUP ]]; then
        cd $workdir
        unset $(grep -v '^#' .env | sed -E 's/(.*)=.*/\1/' | xargs)
    fi
}

msg() {
    local exit_code=$?
    local args="$@"
    
    read -r lineno _ < <(caller 0)
    ((lineno--))

    if [[ $exit_code != 0 ]]; then
        echo -e "${red}[ error ]${grey} line $lineno: ${args[@]} $fail${reset}"
        exit $exit_code
    fi

    echo -e "${green}[ info ]${grey} ${args[@]} $success${reset}"
}

deps() {
    local brew=$(which brew)
    local brew_install="curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
    local pkgs=("linode-cli" "rclone" "kubectl" "coreutils" "jq" "python3" "curl" "xclip" "age" "bash")

    if [[ -z $brew ]]; then
        msg "installing homebrew"
        eval $brew_install

        msg "run deps again to install required packages"
        exit 0
    fi
    
    mag "installing required packages"
    for i in "${pkgs[@]}"; do
        brew install -y $i
    done
}

wait-for-it() {
    local timeout=300
    local err_msg="timeout exceeded"
    local progress=(" " "." ".." "...")

    cd $workdir
    if [[ $1 == "kube" ]]; then
        while [[ $timeout > 0 ]]; do
            for i in "${progress[@]}"; do
                # export KUBECONFIG=$LINODE_LKE_KUBECONFIG
                local result=$(kubectl wait --for=create configmap/welcome -n apl-operator --timeout=1s 2>&1)

                 printf "\r\033[K${green}[ info ]${grey} installing app platform%-3s${reset}" "$i"

                if [[ $result =~ "condition met" ]]; then
                     printf "\r\033[K${green}[ info ]${grey} installing app platform %s${reset}"  "$(echo -ne $success)"
                     echo && msg "apl is ready"
                     return
                fi

                sleep 1
                ((timeout--))
            done
        done
    fi

    if [[ $1 == "lke" ]]; then
        while [[ $timeout > 0 ]]; do
            local node_status=$(linode-cli lke pools-list $lke_id --json | jq -r .[].nodes[].status | tr '\n' ' ')
            local report=$(echo ${node_status%[[:space:]]} | tr ' ' '|')

            for i in "${progress[@]}"; do
                printf "\r\033[K${green}[ info ]${grey} provisioning nodes %s%-3s %s${reset}" "(${report})" "$i" 

                if [[ ${report} == "ready|ready|ready" ]]; then
                    printf "\r\033[K${green}[ info ]${grey} provisioning nodes %s %s${reset}" "(${report})" "$(echo -ne $success)"
                    echo && msg "node pool is ready"
                    return
                fi

                sleep 1
                ((timeout--))
            done
        done
    fi

    if [[ $timeout == 0 ]]; then
        echo
        false
        msg "$err_msg"
    fi
}

setup() {
    local linode_conf="$HOME/.config/linode-cli"
    cd $workdir

    set -a
    source .env
    set +a

    mkdir -p $HOME/.config
    [[ -f $linode_conf ]] && [[ ! -f $linode_conf.bak ]] && echo $linode_conf > $linode_conf.bak
        
    config:linode-cli > $HOME/.config/linode-cli
    msg "configure linode-cli"

    if [[ ! -f key.txt ]]; then
        false
        msg "missing key.txt file"
    fi

    [[ -f .env.enc ]] && age -d -i key.txt .env.enc > .env
}

config:linode-cli() {
    echo "[DEFAULT]"
    echo "default-user = devrel"
    echo "[devrel]"
    echo
    echo "token = $LINODE_TOKEN"
    echo "region = $LINODE_REGION"
    echo "type = $LINODE_TYPE"
    echo "suppress-version-warning = true"
}

##### git repo funcs #####
repo() {
    local repo_url="https://${GH_TOKEN}@github.com/$ORG/$REPO.git"

    cd $workdir
    if [[ ! -d "$REPO" ]]; then
        local clone_txt=$(git clone $repo_url 2>&1)
        repo:print-lines "$clone_txt"
    fi

    cd $workdir/$REPO
    git remote set-url origin $repo_url

    if [[ $(git branch --show-current) != "main" ]]; then
        local checkout_txt=$(git checkout -f main 2>&1)
        repo:print-lines "$checkout_txt"
    fi

    if [[ $1 == "rm" ]]; then
        msg "reset repo"

        if [[ $(git branch | grep -o $GIT_BRANCH) ]]; then
            local branch_txt=$(git branch -D $GIT_BRANCH 2>&1)
            repo:print-lines "$branch_txt"
            msg "delete local branch"
        fi

        if [[ -n $(git branch -r | grep -o $GIT_BRANCH) ]]; then        
            local push_txt=$(git push origin --delete $GIT_BRANCH 2>&1)
            repo:print-lines "$push_txt"
            msg "delete remote branch"
        fi

        local prune_txt=$(git fetch --prune 2>&1)
        [[ -n $prune_txt ]] && repo:print-lines "$prune_txt" || true
        msg "clean up state"
    fi
}

repo:print-lines() {
    local txt="$@"
    OLD_IFS=$IFS
    IFS='\n'
    for i in "$txt"; do
        printf "\n${green}[ info ]${grey} %s${reset}" "$i"
    done
    echo
    IFS=$OLD_IFS
}

repo:apps() {
    cd $workdir/$REPO

    [[ $(git branch --show-current) != "main" ]] && git checkout main >/dev/null 2>&1
    local pull_txt=$(git pull origin main 2>&1)
    repo:print-lines "$pull_txt"

    local fetch_txt=$(git fetch --all 2>&1)
    repo:print-lines "$fetch_txt"
    sleep 2

    if [[ -z $(git branch -a | grep -o $GIT_BRANCH) ]]; then
        false
        msg "missing app platform gitops branch"
    fi

    local checkout_txt=$(git checkout $GIT_BRANCH 2>&1)
    repo:print-lines "$checkout_txt"

    pull_txt=$(git pull origin $GIT_BRANCH 2>&1)
    repo:print-lines "$pull_txt"
    
    sleep 1
    local apps=("alertmanager" "harbor" "knative" "kubeflow-pipelines" "kyverno" "loki" "otel" "tekton" "trivy")
    for i in "${apps[@]}"; do
        local file="env/apps/$i.yaml"
        sed -i 's/enabled: false/enabled: true/g' $file
    done

    printf "\n${yellow}[ input ]${grey} commit changes? (y/n) ${reset}"
    read -r prompt
    if [[ $prompt == "y" ]]; then
        git add .

        local commit_txt=$(git commit -m 'enable apps with git' 2>&1)
        repo:print-lines "$commit_txt"

        push_txt=$(git push -u origin $GIT_BRANCH 2>&1)
        repo:print-lines "$push_txt"
    fi
}

repo:prod() {
    cd $workdir/$REPO
    [[ $(git branch --show-current) != "main" ]] && git checkout main >/dev/null 2>&1
    sleep 1
    
    local pull_txt=$(git pull origin main 2>&1)
    repo:print-lines "$pull_txt"

    tmp=$(mktemp -d)
    mkdir $tmp/teams $tmp/manifests

    rsync -avpq env/teams/ $tmp/teams/
    rsync -avpq env/manifests/ $tmp/manifests/
    [[ -z $lke_id ]] && linode:lke-id
    sed -i -e "s/PLACEHOLDER/headlamp.lke${lke_id}.akamai-apl.net/g" $tmp/manifests/gateway-headlamp.yaml

    local checkout_txt=$(git checkout $GIT_BRANCH 2>&1)
    repo:print-lines "$checkout_txt"

    pull_txt=$(git pull origin $GIT_BRANCH 2>&1)
    repo:print-lines "$pull_txt"

    local argocd_dst="env/manifests/namespaces/argocd/applications"
    local route_dst="env/manifests/namespaces/headlamp/httproute"

    declare -A src_files=(
        [argocd-headlamp.yaml]="$argocd_dst"
        [gateway-headlamp.yaml]="$route_dst"
        [teams]="env/teams"
    )

    mkdir -p $argocd_dst $route_dst
    for key in "${!src_files[@]}"; do
        if [[ $key == "teams" ]]; then
            rsync -qavp $tmp/$key/ env/teams/
            continue
        fi

        local dst="${src_files[$key]}"
        rsync -qavp $tmp/manifests/$key $dst/$key
    done

    git add .
    local status_txt=$(git status 2>&1)
    repo:print-lines

    local commit=$(git commit -m 'add prod demo teams and manifests' 2>&1)
    repo:print-lines  "$commit"

    local push_txt=$(git push -u origin $GIT_BRANCH 2>&1)
    repo:print-lines "$push_txt"
}

repo:reset() {
    repo "rm"
    sleep 2
    repo
}

##### cloud infra funcs #####
linode:obj() {
    local ep="https://api.linode.com/v4/object-storage/buckets"

    # purge related buckets
    local buckets=$(curl -s -H 'accept: application/json' -H "authorization: Bearer $LINODE_TOKEN" $ep | jq -r 2>&1)
    echo -e "buckets:\n$buckets"

    if [[ $PURGE_ALL ]]; then
        local filtered=($(echo $buckets | jq -r .data[].label))
        [[ -n $filtered ]] && { echo $filtered; return; }
    fi

    local filtered=($(echo $buckets | jq -r '.data[] | select(.label | startswith("lke")).label' 2> /dev/null))

    if [[ -n $filtered ]] && [[ $filtered != "null" ]]; then
        msg "purging obj buckets"
        for i in "${filtered[@]}"; do
            rclone purge s3remote:$i
            msg "delete $i"
        done
    fi
}

linode:volumes() {
    msg "purging volumes"

    for i in $(linode-cli volumes ls --json | jq -r '.[] | select(.linode_id == null).id'); do
        linode-cli volumes rm $i >/dev/null
        msg "deleted $i"
    done
}

linode:cluster() {
    local err_msg="Label must be unique among your Clusters"

    linode:lke-id || true
    if [[ $1 == "rm" ]]; then
        if [[ -n $lke_id ]]; then
            linode-cli lke cluster-delete $lke_id
            msg "delete lke cluster"
            sleep 1
        fi
        return
    fi

    local result=$(linode-cli lke cluster-create \
      --apl_enabled true \
      --label "$LINODE_LKE_LABEL" \
      --region "$LINODE_REGION" \
      --k8s_version 1.36 \
      --control_plane.high_availability true \
      --node_pools.type g7-dedicated-16-8 \
      --node_pools.count 3 --json 2>&1)

    local err=$(echo $result |  grep -oP '\[{.*\}]' | jq -r .[].reason)
    if [[ $err != "null" ]]; then
        if [[ $err != $err_msg ]]; then
            false
            msg "$err"
        fi

        msg "cluster exists"
        msg "use 'reset' instead"
        return
    fi

    linode:lke-id
    msg "deploy lke cluster"
    
    sleep 1
    wait-for-it "lke"
    linode:kubeconfig
}

linode:lke-id() {
    lke_id=$(linode-cli lke clusters-list --label "$LINODE_LKE_LABEL" --json | jq -r .[].id)
}

linode:reset() {
    linode:cluster "rm"
    linode:obj
    linode:volumes "verbose"
    linode:cluster
}

linode:kubeconfig() {
    local err_msg="Cluster kubeconfig is not yet available"

    cd $workdir
    linode:lke-id

    if [[ -z $lke_id ]]; then
        false
        msg "missing lke id for fetching kubeconfig"
    fi

    local result=""
    msg "fetching kubeconfig"
    until [[ -n $result ]] && [[ $result != "null" ]]; do
        result=$(linode-cli lke kubeconfig-view $lke_id --json --pretty 2>/dev/null | jq -r .[].kubeconfig)
    done

    echo $result | base64 -d > $KUBECONFIG
    msg "download kubeconfig"
}

##### k8s funcs #####
kubectl-data() {
    local secret_name="platform-admin-initial-credentials"
   
    cd $workdir
    [[ ! -f $KUBECONFIG ]] && linode:kubeconfig 2>&1 > /dev/null
    [[ ! $DATA_ONLY ]] && wait-for-it "kube"

    consoleurl=$(kubectl get configmap welcome -n apl-operator -o jsonpath='{.data.consoleUrl}')
    msg "fetch console url"
    
    username=$(kubectl get secret $secret_name -n keycloak -o jsonpath='{.data.username}' | base64 -d)
    msg "fetch username"

    password=$(kubectl get secret $secret_name -n keycloak -o jsonpath='{.data.password}' | base64 -d)
    msg "fetch password"

    info:apl
}

headlamp() {
    linode:lke-id
    headlamp_token=$(kubectl create token headlamp -n headlamp 2> /dev/null || true)

    [[ -n $lke_id ]] && [[ -n $headlamp_token ]] && headlamp=true

    if [[ $TOKEN_ONLY ]]; then
        [[ $headlamp ]] && info:headlamp >/dev/null
        return
    fi

    [[ $headlamp ]] || false
    msg "headlamp service account token"
    info:headlamp
}

##### info funcs #####
info:apl() {
    echo -e "\n${grey}welcome to app platform${reset}"
    echo -e "${grey}-----------------------${reset}"
    echo -e "${green} apl:consoleUrl    ${grey}$consoleurl${reset}"
    echo -e "${green} apl:username      ${grey}$username${reset}"
    echo -e "${green} apl:initPassword  ${grey}$password${reset}"
    echo -e "${green} apl:password      ${grey}[redacted]${reset}"
}

info:external() {
    echo -e "\n${grey}byo catalog${reset}"
    echo -e "${grey}-----------${reset}"
    echo -e "${green} catalog:url   ${grey}$CATALOG_URL${reset}"
    echo -e "${green} catalog:name  ${grey}$CATALOG_NAME${reset}"
    echo -e "${green} catalog:name  ${grey}$CATALOG_BRANCH${reset}"
}

info:repo() {
    local repo_url="https://github.com/akamai-developers-bot/apl-values"
 
    echo -e "\n${grey}repo info${reset}"
    echo -e "${grey}---------${reset}"
    echo -e "${green} repo:url       ${grey}$repo_url${reset}"
    echo -e "${green} repo:password  ${grey}[redacted]${reset}"
    echo -e "${green} repo:email     ${grey}$GIT_EMAIL${reset}"
    echo -e "${green} repo:branch    ${grey}$GIT_BRANCH${reset}"
}

info:headlamp() {
    linode:lke-id
    headlamp_url="https://headlamp.lke${lke_id}.akamai-apl.net"

    echo -e "\n${grey}headlamp${reset}"
    echo -e "${grey}--------${reset}"
    echo -e "${green} headlamp:url   ${grey}$headlamp_url${reset}"
    echo -e "${green} headlamp:token ${grey}[redacted]${reset}"
}

info:manifests() {
    cd $workdir/$REPO
    [[ $(git branch --show-current) != "$GIT_BRANCH" ]] && git checkout $GIT_BRANCH
    
    
    local result=$(find env/manifests/ -name "*.yaml" | grep -v sealed)
    [[ -z $result ]] && return
    
    echo -e "\n${grey}manifests${reset}"
    echo -e "${grey}---------${reset}"
    for i in $result; do
        local dir=$(dirname $i)
        local file=$(basename $i)
        printf "${green} %-30s ${grey}${dir}\n${reset}" "manifest:${file}"
    done
}

info() {
    [[ -f $KUBECONFIG ]] && DATA_ONLY=true kubectl-data
    info:external
    info:repo

    TOKEN_ONLY=true headlamp
    info:manifests
}

##### copy funcs #####
copy:headlamp() {
    printf "\n${yellow}[ input ]${grey} copy headlamp:url (y/n): ${reset}"
    read -r prompt
    if [[ $prompt == "y" ]]; then
        echo $headlamp_url | pbcopy
        msg "copied to clipboard"
    fi

    printf "\n${yellow}[ input ]${grey} copy headlamp:token (y/n): ${reset}"
    read -r prompt
    if [[ $prompt == "y" ]]; then
        echo $headlamp_token | pbcopy
        msg "copied to clipboard"
    fi
}

copy:apl() {
    DATA_ONLY=true kubectl-data

    printf "\n${yellow}[ input ]${grey} copy apl:consoleUrl (y/n): ${reset}"
    read -r prompt
    if [[ $prompt == "y" ]]; then
        echo $consoleurl | pbcopy
        msg "copied to clipboard"
    fi

    printf "\n${yellow}[ input ]${grey} copy apl:username (y/n): ${reset}"
    read -r prompt
    if [[ $prompt == "y" ]]; then
        echo $username | pbcopy
        msg "copied to clipboard"
    fi

    printf "\n${yellow}[ input ]${grey} copy apl:initPassword (y/n): ${reset}"
    read -r prompt
    if [[ $prompt == "y" ]]; then
        echo $password | pbcopy
        msg "copied to clipboard"
    fi

    printf "\n${yellow}[ input ]${grey} copy apl:password (y/n): ${reset}"
    read -r prompt
    if [[ $prompt == "y" ]]; then
        echo $APL_ADMIN_PASS | pbcopy
        msg "copied to clipboard"
    fi
}

copy:catalog() {
    printf "\n${yellow}[ input ]${grey} copy catalog:name? (y/n): ${reset}"
    read -r prompt
    if [[ $prompt == "y" ]]; then
        echo $CATALOG_NAME | pbcopy
        msg "copied to clipboard"
    fi

    printf "\n${yellow}[ input ]${grey} copy catalog:url? (y/n): ${reset}"
    read -r prompt
    if [[ $prompt == "y" ]]; then
        echo $CATALOG_URL | pbcopy
        msg "copied to clipboard"
    fi

    printf "\n${yellow}[ input ]${grey} copy catalog:branch? (y/n): ${reset}"
    read -r prompt
    if [[ $prompt == "y" ]]; then
        echo $CATALOG_BRANCH | pbcopy
        msg "copied to clipboard"
    fi
}

copy:repo() {
    local repo_url="https://github.com/$ORG/$REPO.git"
    printf "\n${yellow}[ input ]${grey} copy repo:url (y/n): ${reset}"
    read -r prompt
    if [[ $prompt == "y" ]]; then
        echo $repo_url | pbcopy
        msg "copied to clipboard"
    fi

    printf "\n${yellow}[ input ]${grey} copy repo:branch (y/n): ${reset}"
    read -r prompt
    if [[ $prompt == "y" ]]; then
        echo $GIT_BRANCH | pbcopy
        msg "copied to clipboard"
    fi

    printf "\n${yellow}[ input ]${grey} copy repo:password (y/n): ${reset}"
    read -r prompt
    if [[ $prompt == "y" ]]; then
        echo $GH_TOKEN | pbcopy
        msg "copied to clipboard"
    fi

    printf "\n${yellow}[ input ]${grey} copy repo:email (y/n): ${reset}"
    read -r prompt
    if [[ $prompt == "y" ]]; then 
        echo $GIT_EMAIL | pbcopy
        msg "copied to clipboard"
    fi
}

copy:build() {
    local secret_keys=("apl:password" "linode:token" "repo:password")
    local group_keys=("apl" "catalog" "repo")

    TOKEN_ONLY=true headlamp
    if [[ $headlamp ]]; then
        secret_keys+=("headlamp:token")
        group_keys+=("headlamp")
    fi

    count=0
    secret_index=()
    group_index=()

    for i in "${secret_keys[@]}"; do
        ((count++))
        x="$count:$i"
        secret_index+=("$x")
    done

    for i in "${group_keys[@]}"; do
        ((count++))
        x="$count:$i"
        group_index+=("$x")
    done
}

copy() {
    copy:build
    OLD_IFS=$IFS

    declare -A inputs
    printf "\n${grey}%5s${reset}" "secrets"
    printf "\n${grey}%5s${reset}" "-------"
    for i in "${secret_index[@]}"; do
        IFS=: read -r key val <<<$i
        inputs["$key"]="$val"
        printf "\n${grey}%5s: %5s ${val}${reset}" "$key" " "
    done

    printf "\n\n${grey}%5s${reset}" "group vars"
    printf "\n${grey}%5s${reset}" "----------"
    for i in "${group_index[@]}"; do
        IFS=: read -r key val <<<$i
        inputs["$key"]="$val"
        printf "\n${grey}%5s: %5s ${val}${reset}" "$key" " "
    done

    IFS=$OLD_IFS

    while true; do
        printf "\n\n${yellow}[ input ]${grey} select value(s) to copy (int): ${reset}"
        read -r prompt

        if [[ -v inputs[$prompt] ]]; then
            local selected="${inputs[$prompt]}"
            break
        fi

        printf "${yellow}[ warn ]${grey}  input is invalid or out of range - try again"
    done


    case $selected in
        apl) copy:apl;;
        apl:password)
            echo $APL_ADMIN_PASS | pbcopy
            msg "copied to clipboard"
            ;;
        catalog) copy:catalog;;
        linode:token)
            echo $LINODE_TOKEN | pbcopy
            msg "copied to clipboard"
            ;;
        repo) copy:repo;;
        repo:password)
            echo $GH_TOKEN | pbcopy
            msg "copied to clipboard"
            ;;
        headlamp) copy:headlamp;;
        headlamp:token)
            echo $headlamp_token | pbcopy
            msg "copied to clipboard"
            ;;
    esac
}

##### help text #####
help() {
    echo -e "${green}usage:${grey} make [args]${reset}"
    echo
    echo -e "${green}args:${reset}"
    echo -e "  ${grey}apps         enable more apps${reset}"
    echo -e "  ${grey}copy         copy outputs to clipboard${reset}"
    echo -e "  ${grey}clean        cleanup project artifacts${reset}"
    echo -e "  ${grey}deps         install dependencies${reset}"
    echo -e "  ${grey}destroy      teardown project${reset}"
    echo -e "  ${grey}headlamp     get headlamp token${reset}"
    echo -e "  ${grey}info         print all project outputs${reset}"
    echo -e "  ${grey}prod         setup production demo${reset}"
    echo -e "  ${grey}reset        reset project state${reset}"
}

##### main #####
setup
case $1 in
    copy) copy;;
    clean)
        [[ -f $KUBECONFIG ]] && rm $KUBECONFIG
        cleanup
        ;; 
    create)
        repo
        linode:cluster
        kubectl-data
        cleanup
        ;;
    deps) deps;;
    destroy)
        setup
        repo "rm"
        linode:cluster "rm"
        linode:obj
        linode:volumes
        cleanup
        ;;
    apps) repo:apps;;
    headlamp) headlamp;;
    help) help;;
    info) info;;
    obj) linode:obj;;
    prod) repo:prod;;
    reset)
        repo:reset
        linode:reset
        kubectl-data
        ;;
    *) help;;
esac
