# Description:
#   Perform ECS Deployments using Hubot and Lambda
#
# Configuration:
#   USE_HUBOT_AUTH - Reqires hubot-auth module installed and configured (defaults to false)
#   ECS_SHIP_TIMEOUT - Deployment timeout, in seconds. Defaults to 600
#   ECS_SHIP_INTERVAL - How often to poll the ECS event feed, in seconds. Defaults to 15
#   ECS_SHIP_LAMBDA_FUNCTION - Name of ECS lambda function to invoke. Defaults to ecs-deploy
#
# Commands:
#   hubot ship <appliation>@<version> to <environment>
#
# Author:
#  justmiles

AWS = require 'aws-sdk'

LAMBDA_FUNCTION   = process.env['ECS_SHIP_LAMBDA_FUNCTION']  or 'ecs-deploy'
TIMEOUT           = process.env['ECS_SHIP_TIMEOUT']          or 600
INTERVAL          = process.env['ECS_SHIP_INTERVAL']         or 15

module.exports = (robot) ->

  robot.respond /ship ((\S*)@(\S*)(\s*)?)*\s*to\s*(\S*)(\s*--fast)?/i, (msg) ->
    
    # env is the environment to deploy to
    env = msg.match[msg.match.length - 2]
    
    if process.env['USE_HUBOT_AUTH']?
      role = "#{env.toLowerCase()}_deployer"
      user = robot.brain.userForName(msg.message.user.name)
      unless robot.auth.hasRole(user, role)
        msg.reply "Access Denied. You need role #{role} to perform this action."
        return
    
    lambda = new AWS.Lambda()
    ecs = new AWS.ECS()
        
    # fast determins whether or not to manually stop current tasks
    fast = msg.match[msg.match.length - 1]?
    
    # apps contain the <application name>:<version>
    apps = {}
    for deploy in (msg.match[0].match /(\S*)@(\S*)/g)
      r = deploy.match /(.*)@(.*)/
      apps[r[1]] = r[2] if r[1]
    
    console.log apps
    for app, version of apps
      console.log "Request to deploy #{app} at version #{version} to #{env}"
      lambda.invoke {
        FunctionName: LAMBDA_FUNCTION
        InvocationType: 'RequestResponse'
        LogType: 'Tail'
        Payload: JSON.stringify({
          Application: app
          Version: version
          Environment: env
        })
      }, (err, data) ->
        if err
          return msg.send "error invoking lambda: " + err 
        
        if data.Payload
          stderr = JSON.parse(data.Payload)
          if stderr.errorMessage
            msg.send "```error invoking Lambda function: #{stderr.errorMessage}```" 
            console.log stderr, app, version , env
            return console.log 'exiting'
          else
            res = JSON.parse JSON.parse(data.Payload)
            unless res.SuccessfullyInvoked
              return msg.send "Error invoking lambda"
            else
              msg.send "Service #{res.ServiceName}'s task definition has been updated to `#{res.TaskDefinition}`. Deployment queued."
          
              if fast
                ecs.listTasks {
                  cluster: res.ClusterArn
                  serviceName: res.ServiceName
                  desiredStatus: 'RUNNING'
                }, (err, data) ->
                  for taskArn in data.taskArns
                    ecs.stopTask {
                      task: taskArn
                      cluster: res.ClusterArn
                      reason: "Fast deployment requested from from #{robot.name}"
                    }, (err, res) ->
                      return msg.send "Error deleting previous tasks: #{err}" if err
          
              # Begin polling depoyment
              updateMessage = msg.send("```deploying...```")[0].updateMessage
              deploymentTime = new Date
              count = 0
              duration = 0
              deploymentComplete = false
          
              poll = setInterval ->
                count++
                duration += INTERVAL
                ecs.describeServices {
                  cluster: res.ClusterArn
                  services: [res.ServiceName]
                }, (err, data) ->
                  return updateMessage err if err
                  m = []
                  for service in data.services
                    for event in service.events.slice(0,10)
                      if event.createdAt > deploymentTime
                        m.push event.createdAt + " " + event.message
                        deploymentComplete = true if event.message.match 'has reached a steady state'
                          
          
                  if deploymentComplete
                    updateMessage "```(#{secondsToString(duration)}) deployed\n #{m.reverse().join('\n')}```\n:thumbsup:"
                    clearInterval poll
                  else
                    updateMessage "```(#{secondsToString(duration)}) deploying ...#{".".repeat(count)}\n#{m.reverse().join('\n')}```"
              , INTERVAL * 1000
          
              setTimeout ->
                clearInterval poll
              , TIMEOUT * 1000 # five minutes

secondsToString = (seconds) ->
  numyears = Math.floor(seconds / 31536000)
  numdays = Math.floor(seconds % 31536000 / 86400)
  numhours = Math.floor(seconds % 31536000 % 86400 / 3600)
  numminutes = Math.floor(seconds % 31536000 % 86400 % 3600 / 60)
  numseconds = (seconds % 31536000 % 86400 % 3600 % 60).toFixed(0)
  time = ''
  if numyears > 0
    time += numyears + ' Years '
  if numdays > 0
    time += numdays + ' Days '
  if numhours > 0
    time += numhours + 'h '
  if numminutes > 0
    time += numminutes + 'm '
  if numseconds > 0 or time == ''
    time += numseconds + 's'
  time
