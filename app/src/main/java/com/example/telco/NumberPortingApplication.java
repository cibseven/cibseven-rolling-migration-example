package com.example.telco;

import org.camunda.bpm.application.ProcessApplication;
import org.camunda.bpm.application.impl.JakartaServletProcessApplication;

/**
 * Process application for the shared process engine of the JBoss subsystem.
 * The subsystem detects the annotation, reads META-INF/processes.xml and deploys
 * the BPMN files to the engine "default"; the engine module is added to this WAR
 * automatically.
 */
@ProcessApplication("number-porting")
public class NumberPortingApplication extends JakartaServletProcessApplication {
}
