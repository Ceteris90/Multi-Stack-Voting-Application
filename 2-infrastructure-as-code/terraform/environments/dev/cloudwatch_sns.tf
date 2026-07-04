# CloudWatch and SNS resources for monitoring the dev deployment

resource "aws_sns_topic" "alerts" {
  name = "dev-voting-app-alerts"

  tags = {
    Name        = "dev-voting-app-alerts"
    Project     = "Multi-Stack-Voting-App"
    Environment = "Dev"
  }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_log_group" "voting_app" {
  name              = "/voting-app/vote"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "results_app" {
  name              = "/voting-app/results"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "worker_app" {
  name              = "/voting-app/worker"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_metric_filter" "voting_error_filter" {
  name           = "voting-app-error-filter"
  log_group_name = aws_cloudwatch_log_group.voting_app.name
  pattern        = "ERROR"

  metric_transformation {
    name      = "VotingAppErrorCount"
    namespace = "MultiStackVotingApp"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "voting_error_alarm" {
  alarm_name          = "dev-voting-app-error-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.voting_error_filter.metric_transformation[0].name
  namespace           = aws_cloudwatch_log_metric_filter.voting_error_filter.metric_transformation[0].namespace
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Triggers when the voting app emits an error log entry."
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {}
}
