package com.example.telco;

import org.camunda.bpm.engine.delegate.DelegateExecution;
import org.camunda.bpm.engine.delegate.JavaDelegate;

/**
 * Provisions the ported number in the HSS. scenario=technicalFailure: the HSS interface times out,
 * the job is retried (R3/PT10S) and then an incident is raised. The scenario is read on every
 * attempt, so setting scenario=success and retrying the incident lets the instance continue.
 */
public class ProvisionHssDelegate implements JavaDelegate {

  @Override
  public void execute(DelegateExecution execution) {
    ExecutionTrace.record(execution);
    if ("technicalFailure".equals(ExecutionTrace.scenario(execution))) {
      throw new RuntimeException("HSS provisioning interface timeout");
    }
    execution.setVariable("hssProvisioned", true);
  }
}
