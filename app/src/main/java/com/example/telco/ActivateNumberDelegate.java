package com.example.telco;

import org.camunda.bpm.engine.delegate.DelegateExecution;
import org.camunda.bpm.engine.delegate.JavaDelegate;

/** Activates the ported number in the network. */
public class ActivateNumberDelegate implements JavaDelegate {

  @Override
  public void execute(DelegateExecution execution) {
    ExecutionTrace.record(execution);
    execution.setVariable("numberActive", true);
  }
}
