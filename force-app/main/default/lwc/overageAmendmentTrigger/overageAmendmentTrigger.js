import { LightningElement, api, wire, track } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import HAS_OVERAGE_FIELD from '@salesforce/schema/Account.Has_Overage__c';

const FIELDS = [HAS_OVERAGE_FIELD];

export default class OverageAmendmentTrigger extends LightningElement {
    @api recordId;
    @track showModal = false;

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredAccount({ data, error }) {
        if (data) {
            const hasOverage = getFieldValue(data, HAS_OVERAGE_FIELD);
            if (hasOverage && !this.showModal) {
                this.showModal = true;
            }
        } else if (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error loading account',
                message: error.body?.message,
                variant: 'error'
            }));
        }
    }

    handleModalClose() {
        this.showModal = false;
    }

    handleModalSubmit(event) {
        this.showModal = false;
    }
}
