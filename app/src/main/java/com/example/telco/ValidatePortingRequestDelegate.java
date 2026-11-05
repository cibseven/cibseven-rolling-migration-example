package com.example.telco;

import org.camunda.bpm.engine.delegate.BpmnError;
import org.camunda.bpm.engine.delegate.DelegateExecution;
import org.camunda.bpm.engine.delegate.JavaDelegate;

/** Validates the port-in request. scenario=reject: the donor operator rejects it (business error). */
public class ValidatePortingRequestDelegate implements JavaDelegate {

  static final String DEFAULT_WAIT_DURATION = "PT30S";

  @Override
  public void execute(DelegateExecution execution) {
    ExecutionTrace.record(execution);
    if (!execution.hasVariable("waitDuration")) {
      execution.setVariable("waitDuration", DEFAULT_WAIT_DURATION);
    }
    if ("reject".equals(ExecutionTrace.scenario(execution))) {
      execution.setVariable("rejectionReason",
          "Donor operator " + execution.getVariable("donorOperator") + " rejected the porting request");
      throw new BpmnError("PORTING_REJECTED", "Donor operator rejected the porting request");
    }
  }
}
