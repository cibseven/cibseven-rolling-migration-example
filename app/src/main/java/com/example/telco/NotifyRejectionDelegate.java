package com.example.telco;

import org.camunda.bpm.engine.delegate.DelegateExecution;
import org.camunda.bpm.engine.delegate.JavaDelegate;

/** Informs the customer that the porting request was rejected. */
public class NotifyRejectionDelegate implements JavaDelegate {

  @Override
  public void execute(DelegateExecution execution) {
    ExecutionTrace.record(execution);
    execution.setVariable("customerNotified", true);
  }
}
