
suppressPackageStartupMessages({
  library(shiny)
})
shiny::runApp('/home/keaton/CloudPulse/lib/FInOpsApp.R', 
             host='127.0.0.1', 
             port=3456, 
             launch.browser=FALSE)
