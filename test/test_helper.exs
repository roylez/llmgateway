# Stop the application to prevent it from managing Router/Bandit
# Tests start their own Router instances
Application.stop(:llmgateway)

ExUnit.start()
